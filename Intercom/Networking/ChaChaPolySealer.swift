import CryptoKit
import Foundation
import Synchronization

/// Authenticated encryption of one Network framework link (`PacketSealer` for CryptoKit).
///
/// Sealed payload layout:
///
///     counter (7 bytes, little-endian) | ChaChaPoly ciphertext | 16-byte tag
///
/// The 12-byte ChaChaPoly nonce is `direction (1) ‖ sender epoch (4, LE) ‖ counter (7, LE)`. Every link
/// has its own pair of keys (see `PairingKey.sessionKeys(for:)`), the direction byte separates the two
/// halves and the epoch changes on every transport start, so a nonce can never repeat under one key.
/// The 14-byte datagram header is the additional authenticated data.
///
/// Received counters pass a 64-wide `ReplayWindow`: checked before the (comparatively expensive)
/// decryption, recorded only after it succeeded, so forged datagrams cannot poison the window.
///
/// Thread safety: `seal` runs concurrently on the audio capture thread and the transport queue, so
/// the send counter is atomic; `open` guards the replay window with a lock.
final class ChaChaPolySealer: PacketSealer, @unchecked Sendable {
    static let counterBytes = 7
    static let tagBytes = 16
    /// The counter must fit in 7 bytes; at 60 datagrams per second that is 38 million years.
    static let maxCounter: UInt64 = (1 << 56) - 1

    private enum Direction: UInt8 {
        case dialerToListener = 0
        case listenerToDialer = 1
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: Direction
    private let receiveDirection: Direction
    private let localEpoch: UInt32
    private let remoteEpoch: UInt32
    private let sendCounter = Atomic<UInt64>(0)
    private let replayLock = UnfairLock()
    private var replayWindow = ReplayWindow()

    init(key: PairingKey, context: LinkKeyContext) {
        let keys = key.sessionKeys(for: context)
        if context.isLocalDialer {
            sendKey = keys.dialerToListener
            receiveKey = keys.listenerToDialer
            sendDirection = .dialerToListener
            receiveDirection = .listenerToDialer
        } else {
            sendKey = keys.listenerToDialer
            receiveKey = keys.dialerToListener
            sendDirection = .listenerToDialer
            receiveDirection = .dialerToListener
        }
        localEpoch = context.localEpoch
        remoteEpoch = context.remoteEpoch
    }

    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]? {
        let counter = sendCounter.add(1, ordering: .sequentiallyConsistent).newValue
        guard counter <= Self.maxCounter,
              let nonce = try? ChaChaPoly.Nonce(data: Self.nonce(direction: sendDirection, epoch: localEpoch, counter: counter)),
              let box = try? ChaChaPoly.seal(payload, using: sendKey, nonce: nonce, authenticating: header) else {
            return nil
        }
        var sealed = [UInt8]()
        sealed.reserveCapacity(Self.counterBytes + payload.count + Self.tagBytes)
        Self.appendCounter(counter, to: &sealed)
        sealed.append(contentsOf: box.ciphertext)
        sealed.append(contentsOf: box.tag)
        return sealed
    }

    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]? {
        guard sealed.count >= Self.counterBytes + Self.tagBytes else { return nil }
        var counter: UInt64 = 0
        for index in 0..<Self.counterBytes {
            counter |= UInt64(sealed[index]) << (8 * UInt64(index))
        }
        replayLock.lock()
        let isFresh = replayWindow.wouldAccept(counter)
        replayLock.unlock()
        guard isFresh else { return nil }

        let tagStart = sealed.count - Self.tagBytes
        guard let nonce = try? ChaChaPoly.Nonce(data: Self.nonce(direction: receiveDirection, epoch: remoteEpoch, counter: counter)),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce,
                                                  ciphertext: sealed[Self.counterBytes..<tagStart],
                                                  tag: sealed[tagStart...]),
              let plaintext = try? ChaChaPoly.open(box, using: receiveKey, authenticating: header) else {
            return nil
        }

        replayLock.lock()
        // A concurrent copy of the same datagram may have been accepted in the meantime.
        let isFirstCopy = replayWindow.insert(counter)
        replayLock.unlock()
        return isFirstCopy ? [UInt8](plaintext) : nil
    }

    private static func nonce(direction: Direction, epoch: UInt32, counter: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [direction.rawValue]
        bytes.reserveCapacity(12)
        bytes.appendLittleEndian(epoch)
        appendCounter(counter, to: &bytes)
        return bytes
    }

    private static func appendCounter(_ counter: UInt64, to bytes: inout [UInt8]) {
        for index in 0..<counterBytes {
            bytes.append(UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))))
        }
    }
}
