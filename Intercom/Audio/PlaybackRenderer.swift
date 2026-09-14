import AVFoundation
import Foundation
import Synchronization

/// The real-time half of playback: fills `AVAudioSourceNode` render requests from the jitter buffer
/// and mixes notification cues on top.
///
/// The source node's block captures this object strongly (no `weak self` load per cycle) and calls
/// `render`, which obeys the real-time rules:
/// * all memory (sample scratch, cue samples, cue table, render-thread state) is allocated in `init`;
/// * the jitter buffer is only ever try-locked (`JitterBuffer.pull(into:)`);
/// * cross-thread communication is `Atomic` only: another thread *requests* a cue by storing its
///   number, and the render thread takes the request with `exchange` and keeps the play position in
///   memory only it touches;
/// * every early return zeroes the output and flags it as silence.
final class PlaybackRenderer: @unchecked Sendable {
    /// Largest render request served; larger ones (never seen in practice) output silence.
    static let maximumFrameCount = 16_384

    let jitterBuffer: JitterBuffer
    private let counters: AudioMetricsCounters
    private let scratch: UnsafeMutablePointer<Int16>

    private let cueSamples: UnsafeMutablePointer<Int16>
    private let cueSampleCount: Int
    private let cueStarts: UnsafeMutablePointer<Int>
    private let cueEnds: UnsafeMutablePointer<Int>
    private let cueCount: Int
    /// 0 = nothing pending, n > 0 = start cue with raw value n − 1, −1 = silence any cue.
    private let cueRequest = Atomic<Int>(0)

    private struct RenderState {
        var cuePosition = 0
        var cueEnd = 0
        var previousHostTime: UInt64 = 0
    }

    /// Render thread only.
    private let state: UnsafeMutablePointer<RenderState>
    /// Peak of the peer's voice in the last render cycle, as `Float.bitPattern`.
    private let outputPeakBits = Atomic<UInt32>(0)

    init(jitterBuffer: JitterBuffer, counters: AudioMetricsCounters, cues: CueToneBank = .standard) {
        self.jitterBuffer = jitterBuffer
        self.counters = counters
        scratch = UnsafeMutablePointer<Int16>.allocate(capacity: Self.maximumFrameCount)
        scratch.initialize(repeating: 0, count: Self.maximumFrameCount)

        let sampleCount = cues.samples.count
        let cueStorage = UnsafeMutablePointer<Int16>.allocate(capacity: max(1, sampleCount))
        cueStorage.initialize(repeating: 0, count: max(1, sampleCount))
        cues.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, sampleCount > 0 {
                cueStorage.update(from: base, count: sampleCount)
            }
        }
        cueSampleCount = sampleCount
        cueSamples = cueStorage
        cueCount = CueTone.allCases.count
        cueStarts = UnsafeMutablePointer<Int>.allocate(capacity: cueCount)
        cueEnds = UnsafeMutablePointer<Int>.allocate(capacity: cueCount)
        for cue in CueTone.allCases {
            let range = cues.range(of: cue)
            (cueStarts + cue.rawValue).initialize(to: range.lowerBound)
            (cueEnds + cue.rawValue).initialize(to: range.upperBound)
        }
        state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState())
    }

    deinit {
        scratch.deinitialize(count: Self.maximumFrameCount)
        scratch.deallocate()
        cueSamples.deinitialize(count: max(1, cueSampleCount))
        cueSamples.deallocate()
        cueStarts.deinitialize(count: cueCount)
        cueStarts.deallocate()
        cueEnds.deinitialize(count: cueCount)
        cueEnds.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Starts `cue` on the next render cycle, replacing any cue still playing. Any thread.
    func play(_ cue: CueTone) {
        cueRequest.store(cue.rawValue + 1, ordering: .relaxed)
    }

    /// Silences a cue that is still playing. Any thread.
    func cancelCue() {
        cueRequest.store(-1, ordering: .relaxed)
    }

    /// Most recent peak level of the peer's voice (cues excluded), 0…1.
    var outputPeak: Float {
        Float(bitPattern: outputPeakBits.load(ordering: .relaxed))
    }

    // MARK: Render thread

    @inline(__always)
    func render(isSilence: UnsafeMutablePointer<ObjCBool>,
                timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: AVAudioFrameCount,
                bufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let count = Int(frameCount)
        counters.renderCallbacks.add(1, ordering: .relaxed)
        atomicLower(counters.renderFramesMin, to: count)
        atomicRaise(counters.renderFramesMax, to: count)
        if timestamp.pointee.mFlags.contains(.hostTimeValid) {
            let hostTime = timestamp.pointee.mHostTime
            let previous = state.pointee.previousHostTime
            if previous != 0, hostTime > previous {
                atomicRaise(counters.renderMaxIntervalTicks, to: hostTime - previous)
            }
            state.pointee.previousHostTime = hostTime
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let bufferCount = buffers.count
        guard count > 0, count <= Self.maximumFrameCount, bufferCount > 0,
              let raw = buffers[0].mData,
              Int(buffers[0].mDataByteSize) >= count * MemoryLayout<Float>.size else {
            for index in 0..<bufferCount {
                if let data = buffers[index].mData {
                    memset(data, 0, Int(buffers[index].mDataByteSize))
                }
            }
            isSilence.pointee = true
            counters.renderEarlyReturns.add(1, ordering: .relaxed)
            return noErr
        }

        let realSamples = jitterBuffer.pull(into: UnsafeMutableBufferPointer(start: scratch, count: count))
        let output = raw.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for index in 0..<count {
            let value = Float(scratch[index]) / 32_768
            output[index] = value
            peak = max(peak, abs(value))
        }
        outputPeakBits.store(peak.bitPattern, ordering: .relaxed)

        let request = cueRequest.exchange(0, ordering: .relaxed)
        if request > 0, request <= cueCount {
            state.pointee.cuePosition = cueStarts[request - 1]
            state.pointee.cueEnd = cueEnds[request - 1]
        } else if request < 0 {
            state.pointee.cuePosition = state.pointee.cueEnd
        }
        var mixed = 0
        let position = state.pointee.cuePosition
        let remaining = state.pointee.cueEnd - position
        if remaining > 0, position >= 0, position + remaining <= cueSampleCount {
            mixed = CueToneBank.mix(UnsafeBufferPointer(start: cueSamples + position, count: min(remaining, count)),
                                    into: UnsafeMutableBufferPointer(start: output, count: count))
            state.pointee.cuePosition = position + mixed
        }

        // Mono only; blank any extra channels defensively.
        if bufferCount > 1 {
            for index in 1..<bufferCount {
                if let data = buffers[index].mData {
                    memset(data, 0, Int(buffers[index].mDataByteSize))
                }
            }
        }
        isSilence.pointee = ObjCBool(realSamples == 0 && mixed == 0)
        return noErr
    }
}
