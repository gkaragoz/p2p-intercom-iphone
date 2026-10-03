import Foundation

/// The sample rate the intercom captures at, sends over the wire and plays back: the *audio
/// quality* setting. Every rate keeps the 20 ms frame, so a frame is `sampleRate / 50` samples.
///
/// `standard` (16 kHz) is the original wire format and the default. The other rates are only sent to
/// peers that advertise `IntercomProtocol.Network.Capability.multiRateAudio`; a receiver plays at its
/// own rate and resamples whatever arrives (`InboundRateAdapter`). 32 kHz is the ceiling because a
/// 20 ms frame must fit one Wi‑Fi MTU: 640 samples × 2 bytes plus the datagram and packet headers is
/// about 1.3 KB, while 48 kHz would need IP fragmentation.
enum WireRate: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 8 kHz: telephone band, 128 kbit/s.
    case narrow
    /// 16 kHz: wideband, the original format and what Bluetooth hands-free delivers anyway; 256 kbit/s.
    case standard
    /// 24 kHz; 384 kbit/s.
    case high
    /// 32 kHz: super-wideband; 512 kbit/s.
    case highest

    static let `default`: WireRate = .standard

    var id: String { rawValue }

    var sampleRate: Int {
        switch self {
        case .narrow: return 8_000
        case .standard: return 16_000
        case .high: return 24_000
        case .highest: return 32_000
        }
    }

    /// Samples per 20 ms frame: 160 / 320 / 480 / 640.
    var frameSamples: Int { sampleRate / IntercomProtocol.framesPerSecond }

    /// Bytes of one frame's samples on the wire.
    var frameBytes: Int { frameSamples * MemoryLayout<Int16>.size }

    var codec: AudioPacket.Codec {
        switch self {
        case .narrow: return .pcm16Mono8k
        case .standard: return .pcm16Mono16k
        case .high: return .pcm16Mono24k
        case .highest: return .pcm16Mono32k
        }
    }

    init(codec: AudioPacket.Codec) {
        switch codec {
        case .pcm16Mono8k: self = .narrow
        case .pcm16Mono16k: self = .standard
        case .pcm16Mono24k: self = .high
        case .pcm16Mono32k: self = .highest
        }
    }

    static func matching(sampleRate: Int) -> WireRate? {
        allCases.first { $0.sampleRate == sampleRate }
    }

    /// Uncompressed 16-bit mono at this rate.
    var kilobitsPerSecond: Int { sampleRate * 16 / 1000 }

    /// Position in `allCases`; used to index per-rate tables (cue banks, EQ coefficients).
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
