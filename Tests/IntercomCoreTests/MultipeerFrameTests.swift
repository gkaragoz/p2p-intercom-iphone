import Foundation
import XCTest
@testable import IntercomCore

final class MultipeerFrameTests: XCTestCase {
    private let statuses: [RemoteStatus] = [
        RemoteStatus(),
        RemoteStatus(isTalking: true, isMuted: false, mode: .pushToTalk, isAudioPaused: false),
        RemoteStatus(isTalking: false, isMuted: true, mode: .voiceActivated, isAudioPaused: true),
        RemoteStatus(isTalking: true, isMuted: true, mode: .alwaysOn, isAudioPaused: true),
    ]

    func testRoundTrips() throws {
        var frames: [MultipeerFrame] = [
            .audio(AudioPacket(sequence: 7, timestamp: 320, samples: [1, -2, 3])),
            .control(.hello(.init(displayName: "Gökhan", appVersion: "1.0 (1)", protocolVersion: 1))),
            .bye(.userDisconnect),
            .bye(.stopped),
        ]
        for (index, status) in statuses.enumerated() {
            frames.append(.status(status))
            frames.append(.ping(sequence: UInt32(index) &* 0x0101_0101, status: status))
            frames.append(.pong(sequence: UInt32.max - UInt32(index), status: status))
        }
        for frame in frames {
            let data = try frame.encoded()
            XCTAssertEqual(MultipeerFrame.decode(data), frame, "\(frame)")
        }
    }

    func testAudioAndControlKeepTheWireMessageEncoding() throws {
        let packet = AudioPacket(sequence: 1, timestamp: 2, samples: [5])
        XCTAssertEqual(try MultipeerFrame.audio(packet).encoded(), try WireMessage.audio(packet).encoded())
        XCTAssertEqual(try MultipeerFrame.control(.bye).encoded(), try WireMessage.control(.bye).encoded())
    }

    func testUnknownByeReasonDecodesAsOther() {
        XCTAssertEqual(MultipeerFrame.decode(Data([MultipeerFrame.byeTag, 200])), .bye(.other))
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(MultipeerFrame.decode(Data()))
        XCTAssertNil(MultipeerFrame.decode(Data([0x00])))
        XCTAssertNil(MultipeerFrame.decode(Data([MultipeerFrame.byeTag])))
        XCTAssertNil(MultipeerFrame.decode(Data([MultipeerFrame.byeTag, 1, 2])))
        XCTAssertNil(MultipeerFrame.decode(Data([MultipeerFrame.pingTag, 0, 1, 2, 3])))
        XCTAssertNil(MultipeerFrame.decode(Data([MultipeerFrame.pongTag, 0, 1, 2, 3, 4, 5])))
        XCTAssertNil(MultipeerFrame.decode(Data([MultipeerFrame.statusTag])))
        XCTAssertNil(MultipeerFrame.decode(Data([WireMessage.audioTag, 1, 2])))
    }

    func testDecodesSlicesWithNonZeroStartIndex() throws {
        let data = try MultipeerFrame.ping(sequence: 99, status: statuses[1]).encoded()
        let padded = Data([0xFF]) + data
        XCTAssertEqual(MultipeerFrame.decode(padded.dropFirst()), .ping(sequence: 99, status: statuses[1]))
        let bye = Data([0xFF, MultipeerFrame.byeTag, ByeReason.duplicate.rawValue]).dropFirst()
        XCTAssertEqual(MultipeerFrame.decode(bye), .bye(.duplicate))
    }

    // MARK: - Invitation context

    func testInvitationRoundTrips() {
        let token = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
        let invitations: [MultipeerInvitation] = [
            .connect(token: token, epoch: 0),
            .connect(token: token, epoch: 0xDEAD_BEEF),
            .bye(token: token, epoch: 42),
            .bye(token: "Gökhan", epoch: UInt32.max),
            .connect(token: "", epoch: 7),
        ]
        for invitation in invitations {
            XCTAssertEqual(MultipeerInvitation.decode(invitation.encoded()), invitation, "\(invitation)")
        }
    }

    func testInvitationLayoutIsTagEpochToken() {
        let data = MultipeerInvitation.bye(token: "ab", epoch: 0x0403_0201).encoded()
        XCTAssertEqual([UInt8](data), [MultipeerInvitation.byeTag, 1, 2, 3, 4, 0x61, 0x62])
        XCTAssertEqual(MultipeerInvitation.connect(token: "ab", epoch: 1).encoded().first, MultipeerInvitation.connectTag)
        XCTAssertEqual(MultipeerInvitation.bye(token: "ab", epoch: 9).token, "ab")
        XCTAssertEqual(MultipeerInvitation.bye(token: "ab", epoch: 9).epoch, 9)
    }

    func testInvitationRejectsMalformedContexts() {
        XCTAssertNil(MultipeerInvitation.decode(Data()))
        // A bare token (no tag) is not a context of this format.
        XCTAssertNil(MultipeerInvitation.decode(Data("3f2504e0-4f89-11d3-9a0c-0305e82c3301".utf8)))
        XCTAssertNil(MultipeerInvitation.decode(Data([MultipeerInvitation.byeTag, 1, 2, 3])))
        XCTAssertNil(MultipeerInvitation.decode(Data([MultipeerInvitation.connectTag, 1, 2, 3, 4, 0xFF, 0xFE])),
                     "token must be UTF-8")
    }

    func testInvitationDecodesSlicesWithNonZeroStartIndex() {
        let invitation = MultipeerInvitation.bye(token: "tok", epoch: 5)
        let padded = (Data([0xEE, 0xEE]) + invitation.encoded()).dropFirst(2)
        XCTAssertEqual(MultipeerInvitation.decode(padded), invitation)
    }
}
