import AVFoundation
import Foundation
import Synchronization

/// The real-time half of playback: fills `AVAudioSourceNode` render requests from the jitter buffer,
/// applies the listening equaliser to the peer's voice and mixes notification cues on top.
///
/// The renderer outlives graph rebuilds: when the engine switches to another `WireRate` it rebuilds
/// its nodes at the new sample rate but keeps this object (and the jitter buffer behind it). So
/// everything that depends on the sample rate is precomputed for every rate in `init` and selected
/// by `activeBank`:
/// * one `CueToneBank` per `WireRate`, all copied into one contiguous sample slab, so a cue plays at
///   the right pitch and speed whatever rate the graph runs at;
/// * one set of `Biquad.Coefficients` per `EQPreset` and `WireRate`, so switching the equaliser or the
///   rate is a table lookup, never a filter design, on the render thread.
///
/// The source node's block captures this object strongly (no `weak self` load per cycle) and calls
/// `render`, which obeys the real-time rules:
/// * all memory (sample scratch, cue slab, cue table, EQ coefficient table and band states,
///   render-thread state) is allocated in `init`;
/// * the jitter buffer is only ever try-locked (`JitterBuffer.pull(into:)`);
/// * cross-thread communication is `Atomic` only: another thread *requests* a cue or an EQ preset by
///   storing its number, and the render thread takes the request with `exchange` and keeps the play
///   position and the filter states in memory only it touches; the active bank is loaded once per
///   cycle and only that bank's table entries are used, so a change at any moment is memory-safe;
/// * every early return zeroes the output and flags it as silence.
final class PlaybackRenderer: @unchecked Sendable {
    /// Largest render request served; larger ones (never seen in practice) output silence.
    static let maximumFrameCount = 16_384

    let jitterBuffer: JitterBuffer
    private let counters: AudioMetricsCounters
    private let scratch: UnsafeMutablePointer<Int16>

    /// Every bank's samples back to back, in `WireRate.allCases` order.
    private let cueSamples: UnsafeMutablePointer<Int16>
    private let cueSampleCount: Int
    /// Absolute positions into `cueSamples`, indexed `bank * cueCount + cue`.
    private let cueStarts: UnsafeMutablePointer<Int>
    private let cueEnds: UnsafeMutablePointer<Int>
    private let cueCount: Int
    /// Number of cue banks and EQ coefficient sets: `WireRate.allCases.count`.
    private let bankCount: Int
    /// 0 = nothing pending, n > 0 = start cue with raw value n − 1, −1 = silence any cue.
    private let cueRequest = Atomic<Int>(0)
    /// Index (`WireRate.index`) of the bank the graph currently plays at.
    private let activeBank: Atomic<Int>

    /// Coefficients of every preset at every rate, indexed
    /// `(preset * bankCount + bank) * eqMaxBands + band`; bands a preset does not use are `identity`.
    private let eqTable: UnsafeMutablePointer<Biquad.Coefficients>
    /// Active bands of every preset at every rate, indexed `preset * bankCount + bank` (a preset can
    /// drop a band at a low rate, so the count is per rate, not per preset).
    private let eqBandCount: UnsafeMutablePointer<Int>
    /// Delay lines of the bands in use, `eqMaxBands` of them. Render thread only.
    private let eqStates: UnsafeMutablePointer<Biquad.State>
    private let eqPresetCount: Int
    private let eqMaxBands: Int
    /// 0 = nothing pending, n > 0 = switch to the preset with index n − 1.
    private let eqRequest = Atomic<Int>(0)

    private struct RenderState {
        var cuePosition = 0
        var cueEnd = 0
        /// Bank the current cue was started from; the cue is silenced when the bank changes.
        var cueBank: Int
        /// `EQPreset.index` in use; 0 (`off`) skips the filter.
        var eqPreset = 0
        /// Bank whose coefficients the band states belong to.
        var eqBank: Int
        var previousHostTime: UInt64 = 0
    }

    /// Render thread only.
    private let state: UnsafeMutablePointer<RenderState>
    /// Peak of the peer's voice in the last render cycle, as `Float.bitPattern`.
    private let outputPeakBits = Atomic<UInt32>(0)

    /// `cues` holds one bank per `WireRate`, in `WireRate.allCases` order. The renderer starts on
    /// the `WireRate.standard` bank; `setActiveRate(_:)` moves it when the graph is rebuilt.
    init(jitterBuffer: JitterBuffer, counters: AudioMetricsCounters, cues: [CueToneBank]) {
        let banks = WireRate.allCases.count
        precondition(cues.count == banks, "PlaybackRenderer needs one CueToneBank per WireRate, in WireRate.allCases order")
        self.jitterBuffer = jitterBuffer
        self.counters = counters
        scratch = UnsafeMutablePointer<Int16>.allocate(capacity: Self.maximumFrameCount)
        scratch.initialize(repeating: 0, count: Self.maximumFrameCount)

        bankCount = banks
        cueCount = CueTone.allCases.count
        let initialBank = WireRate.standard.index
        activeBank = Atomic<Int>(initialBank)

        // One slab for all banks; the table holds absolute positions so the render thread never
        // adds a bank offset.
        let sampleCount = cues.reduce(0) { $0 + $1.samples.count }
        let cueStorage = UnsafeMutablePointer<Int16>.allocate(capacity: max(1, sampleCount))
        cueStorage.initialize(repeating: 0, count: max(1, sampleCount))
        let starts = UnsafeMutablePointer<Int>.allocate(capacity: banks * cueCount)
        let ends = UnsafeMutablePointer<Int>.allocate(capacity: banks * cueCount)
        var offset = 0
        for (bankIndex, bank) in cues.enumerated() {
            let bankSampleCount = bank.samples.count
            bank.samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress, bankSampleCount > 0 {
                    (cueStorage + offset).update(from: base, count: bankSampleCount)
                }
            }
            for cue in CueTone.allCases {
                let range = bank.range(of: cue)
                let slot = bankIndex * cueCount + cue.rawValue
                (starts + slot).initialize(to: offset + range.lowerBound)
                (ends + slot).initialize(to: offset + range.upperBound)
            }
            offset += bankSampleCount
        }
        cueSampleCount = sampleCount
        cueSamples = cueStorage
        cueStarts = starts
        cueEnds = ends

        // Every preset designed for every rate up front: the render thread only ever reads.
        let presets = EQPreset.allCases.count
        let maxBands = BiquadChain.maxBands
        eqPresetCount = presets
        eqMaxBands = maxBands
        let table = UnsafeMutablePointer<Biquad.Coefficients>.allocate(capacity: presets * banks * maxBands)
        table.initialize(repeating: Biquad.identity, count: presets * banks * maxBands)
        let bandCounts = UnsafeMutablePointer<Int>.allocate(capacity: presets * banks)
        bandCounts.initialize(repeating: 0, count: presets * banks)
        for preset in EQPreset.allCases {
            for rate in WireRate.allCases {
                let designed = preset.coefficients(sampleRate: Double(rate.sampleRate))
                let used = min(designed.count, maxBands)
                let slot = preset.index * banks + rate.index
                bandCounts[slot] = used
                for band in 0..<used {
                    table[slot * maxBands + band] = designed[band]
                }
            }
        }
        eqTable = table
        eqBandCount = bandCounts
        eqStates = UnsafeMutablePointer<Biquad.State>.allocate(capacity: maxBands)
        eqStates.initialize(repeating: Biquad.State(), count: maxBands)

        state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState(cueBank: initialBank, eqBank: initialBank))
    }

    /// Single-bank form: `cues` serves the rate whose sample rate it was rendered at (`standard` when
    /// no `WireRate` matches), and the other rates get a bank synthesized at the same amplitude. With
    /// the default `.standard` bank the standard slot is that very bank, so playback at the default
    /// rate is unchanged.
    convenience init(jitterBuffer: JitterBuffer, counters: AudioMetricsCounters, cues: CueToneBank = .standard) {
        let served = WireRate.matching(sampleRate: cues.sampleRate) ?? .standard
        let banks = WireRate.allCases.map { rate in
            rate == served ? cues : CueToneBank(sampleRate: rate.sampleRate, amplitude: cues.amplitude)
        }
        self.init(jitterBuffer: jitterBuffer, counters: counters, cues: banks)
    }

    deinit {
        scratch.deinitialize(count: Self.maximumFrameCount)
        scratch.deallocate()
        cueSamples.deinitialize(count: max(1, cueSampleCount))
        cueSamples.deallocate()
        cueStarts.deinitialize(count: bankCount * cueCount)
        cueStarts.deallocate()
        cueEnds.deinitialize(count: bankCount * cueCount)
        cueEnds.deallocate()
        eqTable.deinitialize(count: eqPresetCount * bankCount * eqMaxBands)
        eqTable.deallocate()
        eqBandCount.deinitialize(count: eqPresetCount * bankCount)
        eqBandCount.deallocate()
        eqStates.deinitialize(count: eqMaxBands)
        eqStates.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Selects the cue bank and EQ coefficient set of the rate the next graph plays at. Engine queue,
    /// while the engine is stopped or being rebuilt, so no render is in flight; a render racing it
    /// would still be safe, because it reads the index once and the tables never change.
    func setActiveRate(_ rate: WireRate) {
        activeBank.store(rate.index, ordering: .relaxed)
    }

    /// Applies a listening EQ preset to the peer's voice (not to the cues) from the next render cycle
    /// on. Any thread.
    func setListeningEQ(_ preset: EQPreset) {
        eqRequest.store(preset.index + 1, ordering: .relaxed)
    }

    /// Starts `cue` on the next render cycle, replacing any cue still playing. Any thread.
    func play(_ cue: CueTone) {
        cueRequest.store(cue.rawValue + 1, ordering: .relaxed)
    }

    /// Silences a cue that is still playing. Any thread.
    func cancelCue() {
        cueRequest.store(-1, ordering: .relaxed)
    }

    /// Most recent peak level of the peer's voice (cues and EQ excluded), 0…1.
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
        // Measured before the EQ so the meter shows the peer's voice, not the preset's boost.
        outputPeakBits.store(peak.bitPattern, ordering: .relaxed)

        // The bank is read once per cycle; cue positions and EQ coefficients below come only from
        // that bank's table entries. The store never writes an invalid index; the check merely keeps
        // any value memory-safe.
        let loadedBank = activeBank.load(ordering: .relaxed)
        let bank = loadedBank >= 0 && loadedBank < bankCount ? loadedBank : state.pointee.eqBank

        // Listening EQ on the peer's voice only; the cues are mixed in afterwards, unfiltered. Same
        // hand-over as the cue request: the UI stores a preset number, the render thread takes it
        // with one exchange. With the preset off the whole block costs one exchange, one load and
        // two compares per cycle.
        let requestedPreset = eqRequest.exchange(0, ordering: .relaxed)
        if requestedPreset > 0, requestedPreset <= eqPresetCount {
            state.pointee.eqPreset = requestedPreset - 1
            zeroEQStates()
        }
        if bank != state.pointee.eqBank {
            // Delay lines built with another rate's coefficients would ring at the wrong frequency.
            state.pointee.eqBank = bank
            zeroEQStates()
        }
        let preset = state.pointee.eqPreset
        if preset != 0 {
            let slot = preset * bankCount + bank
            let bandCount = eqBandCount[slot]
            let tableBase = slot * eqMaxBands
            for band in 0..<bandCount {
                let coefficients = eqTable[tableBase + band]
                var bandState = eqStates[band]
                for index in 0..<count {
                    output[index] = Biquad.process(output[index], coefficients, &bandState)
                }
                eqStates[band] = bandState
            }
            // A boost can push a loud peer past full scale; clip here rather than in the hardware.
            for index in 0..<count {
                output[index] = min(1, max(-1, output[index]))
            }
        }

        let request = cueRequest.exchange(0, ordering: .relaxed)
        if request > 0, request <= cueCount {
            let slot = bank * cueCount + (request - 1)
            state.pointee.cuePosition = cueStarts[slot]
            state.pointee.cueEnd = cueEnds[slot]
            state.pointee.cueBank = bank
        } else if request < 0 {
            state.pointee.cuePosition = state.pointee.cueEnd
        }
        // The engine cancels cues on a rate change; should one still be mid-play when the bank moves,
        // it would continue at the wrong pitch, so it is silenced here as well.
        if state.pointee.cueBank != bank {
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

    /// Forgets the EQ delay lines: the next samples start from silence. Render thread only.
    @inline(__always)
    private func zeroEQStates() {
        for band in 0..<eqMaxBands {
            eqStates[band] = Biquad.State()
        }
    }
}
