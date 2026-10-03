import AVFoundation
import Foundation
import os

/// Applies the transmit voice effect (`VoiceEffectPreset`) and the microphone EQ (`EQPreset`) to
/// the 20 ms wire frames on the capture worker thread, so the *peer* hears the processed voice.
///
///     Int16 frame ──▶ Float ──▶ [offline AVAudioEngine: source ▶ time-pitch ▶ distortion ▶ reverb ▶ mixer]
///                           ──▶ recipe EQ (BiquadChain) ──▶ transmit EQ (BiquadChain) ──▶ gain ──▶ Int16
///
/// The effect units are Apple's `AVAudioUnit`s, so they need an `AVAudioEngine`; this class owns a
/// *second* engine in offline manual rendering mode and never touches the live capture/playback
/// graph. Manual rendering is synchronous: `renderOffline` pulls the whole chain on the calling
/// thread, so everything here (the FIFO the source node drains, the buffers, the EQ states) belongs
/// to the capture worker and needs no cross-thread hand-off. The worker is a normal thread, so
/// the lock below and the occasional allocation are fine; steady-state work per frame is one
/// render call plus a few multiply-adds per sample.
///
/// Priming: `AVAudioUnitTimePitch` does not pull one output frame's worth of input per render.
/// It runs ahead of its output to fill its analysis window: on its first render it takes about
/// 60 ms of input on top of the frame it renders and keeps that lead from then on (at 24 kHz the
/// lead creeps up in small steps for a dozen frames before it settles). A source that cannot
/// serve such a pull would have to zero-fill, which the peer hears as a hole. So `init` calibrates
/// the graph: with the FIFO holding plenty of zeros it renders `calibrationFrames` frames, pushing
/// one frame per render exactly as `process` will, and records the largest *deficit* (samples
/// pulled minus samples pushed) the source ever saw. The engine is then reset and the FIFO
/// re-primed with `deficit + frameSamples` zeros (one frame of margin). Those zeros sit before the
/// first real sample, so they are pure delay, never a hole, and `latencyMs` reports them (about
/// 80 ms for the pitch presets). A graph whose units pull exactly what they render (distortion
/// and reverb only) shows a deficit of 0 and gets no priming at all. Should a starvation still
/// happen at run time, the source zero-fills, counts it (`starvedSamples`) and `process` pushes
/// one more frame of zeros, at most `maxHeals` times, so the delay grows once instead of the hole
/// repeating.
///
/// Failure policy: every problem degrades to "EQ and gain only" rather than silence. If the engine
/// cannot be built, `isEffectAvailable` is false from the start; if rendering fails
/// `maxConsecutiveRenderFailures` times in a row the engine is released and the flag drops. Both are
/// logged once. `process` always returns exactly as many samples as it was given.
///
/// Threads: `process` on the capture worker; `init`, `tearDown` and the diagnostics from any
/// thread. A single lock serialises them (never a real-time thread).
final class VoiceEffectProcessor: @unchecked Sendable {
    let sampleRate: Double
    let frameSamples: Int
    let effect: VoiceEffectPreset
    let eq: EQPreset

    /// The offline effect engine could be built (false: only EQ/gain apply, or nothing was needed).
    /// Reflects the build (and any later give-up); `tearDown` leaves it alone.
    private(set) var isEffectAvailable = false

    /// Processing delay the effect adds to the transmit path, for the latency diagnostics: the
    /// priming zeros plus what the effect units report themselves. 0 without an engine.
    var latencyMs: Double {
        lock.withLock {
            guard engine != nil else { return 0 }
            return Double(primeSamplesUnlocked) / sampleRate * 1_000 + unitLatencyMs
        }
    }

    /// Source-node starvations seen so far, in samples (diagnostics; should stay 0).
    var starvedSamples: Int {
        lock.withLock { fifo?.starvedSamples ?? 0 }
    }

    /// Zeros currently queued ahead of the voice (the calibrated prime plus any heals).
    var primeSamples: Int {
        lock.withLock { primeSamplesUnlocked }
    }

    /// Frames rendered during calibration; 320 ms of audio, a few milliseconds of CPU.
    static let calibrationFrames = 16
    /// Zeros in the FIFO during calibration: more than any burst the time-pitch unit was seen to
    /// pull, so the calibration itself never starves.
    static let calibrationPrime = 8_192
    /// Extra frames of zeros a run-time starvation may add before we stop trying.
    static let maxHeals = 4
    /// Render failures in a row after which the engine is released and EQ/gain carry on alone.
    static let maxConsecutiveRenderFailures = 50

    private static let log = Logger(subsystem: "intercom", category: "audio.effect")
    private static let int16Scale: Float = 32_768

    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var recipeEQ: BiquadChain
    private var transmitEQ: BiquadChain
    private let gain: Float
    /// True when nothing at all would change the samples: return the input array as is. Written
    /// once in `init`, so `process` reads it without the lock.
    private var isPassthrough = false

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var effectUnits: [AVAudioUnit] = []
    private var output: AVAudioPCMBuffer?
    private var fifo: SampleFIFO?
    private var primeSamplesUnlocked = 0
    private var unitLatencyMs: Double = 0
    private var heals = 0
    private var seenStarvations = 0
    private var consecutiveRenderFailures = 0
    private var loggedRenderFailure = false

    /// Float work buffer; sized for `frameSamples`, regrown only if a bigger frame ever arrives.
    private var scratch: UnsafeMutableBufferPointer<Float>

    init(sampleRate: Double, frameSamples: Int, effect: VoiceEffectPreset, eq: EQPreset) {
        self.sampleRate = sampleRate
        self.frameSamples = frameSamples
        self.effect = effect
        self.eq = eq

        let recipe = effect.recipe
        recipeEQ = BiquadChain(bands: recipe.eqBands, sampleRate: sampleRate)
        transmitEQ = BiquadChain(bands: eq.bands(sampleRate: sampleRate), sampleRate: sampleRate)
        gain = recipe.outputGainDB == 0 ? 1 : Float(pow(10, Double(recipe.outputGainDB) / 20))
        scratch = .allocate(capacity: max(1, frameSamples))
        scratch.initialize(repeating: 0)

        if recipe.needsOfflineEngine {
            do {
                try buildEngine(recipe: recipe)
                isEffectAvailable = true
            } catch {
                Self.log.error("voice effect \(effect.rawValue, privacy: .public) unavailable at \(Int(sampleRate)) Hz, EQ/gain only: \(String(describing: error), privacy: .public)")
                releaseEngine()
                isEffectAvailable = false
            }
        } else {
            isEffectAvailable = true
        }
        isPassthrough = engine == nil && recipeEQ.isEmpty && transmitEQ.isEmpty && gain == 1

        let latency = engine == nil ? 0 : Double(primeSamplesUnlocked) / sampleRate * 1_000 + unitLatencyMs
        Self.log.notice("voice effect \(effect.rawValue, privacy: .public) eq \(eq.rawValue, privacy: .public) at \(Int(sampleRate)) Hz: available=\(self.isEffectAvailable) latency=\(latency, format: .fixed(precision: 1))ms prime=\(self.primeSamplesUnlocked) unit=\(self.unitLatencyMs, format: .fixed(precision: 1))ms")
    }

    deinit {
        tearDown()
        scratch.deallocate()
    }

    /// Returns exactly `frame.count` samples. Capture worker thread only.
    ///
    /// A frame that is not `frameSamples` long (the caller filters those anyway) bypasses the
    /// engine, whose render size is fixed, and only gets EQ and gain.
    func process(_ frame: [Int16]) -> [Int16] {
        if isPassthrough { return frame }
        lock.lock()
        defer { lock.unlock() }

        let count = frame.count
        guard count > 0 else { return frame }
        if scratch.count < count {
            scratch.deallocate()
            scratch = .allocate(capacity: count)
            scratch.initialize(repeating: 0)
        }
        let work = UnsafeMutableBufferPointer(rebasing: scratch[0..<count])
        frame.withUnsafeBufferPointer { source in
            for index in 0..<count {
                work[index] = Float(source[index]) / Self.int16Scale
            }
        }

        if let engine, count == frameSamples {
            render(work, with: engine)
        }

        recipeEQ.process(work)
        transmitEQ.process(work)
        if gain != 1 {
            for index in 0..<count { work[index] *= gain }
        }

        return [Int16](unsafeUninitializedCapacity: count) { buffer, initialized in
            for index in 0..<count {
                buffer[index] = Self.int16(from: work[index])
            }
            initialized = count
        }
    }

    /// Stops the offline engine and drops its nodes; idempotent. The EQ chains stay usable, so a
    /// `process` call after this is EQ/gain only.
    func tearDown() {
        lock.withLock { releaseEngine() }
    }

    // MARK: Offline engine

    private enum BuildError: Error {
        case invalidFormat
        case bufferUnavailable
        case calibrationRender(AVAudioEngineManualRenderingStatus)
    }

    /// Attaches the chain the recipe asks for, switches the engine to offline rendering at the
    /// wire rate and calibrates the FIFO prime. Called from `init` only, before `lock` matters.
    private func buildEngine(recipe: VoiceEffectRecipe) throws {
        guard sampleRate > 0, sampleRate.isFinite, frameSamples > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw BuildError.invalidFormat
        }
        let frameCount = AVAudioFrameCount(frameSamples)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw BuildError.bufferUnavailable
        }
        let fifo = SampleFIFO(capacity: Self.calibrationPrime + 2 * frameSamples)
        let engine = AVAudioEngine()

        // The render block must not capture `self`: the engine holds the node, the node holds the
        // block, and a strong `self` in it would keep the processor alive for ever.
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let wanted = Int(frameCount)
            guard let first = buffers.first, let data = first.mData else {
                fifo.discard(wanted)
                return noErr
            }
            let room = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            fifo.pop(into: data.assumingMemoryBound(to: Float.self), count: min(wanted, room))
            return noErr
        }

        var units: [AVAudioUnit] = []
        if recipe.pitchCents != 0 {
            let timePitch = AVAudioUnitTimePitch()
            timePitch.pitch = recipe.pitchCents
            timePitch.rate = 1
            timePitch.overlap = 8
            units.append(timePitch)
        }
        if let distortion = recipe.distortion {
            let unit = AVAudioUnitDistortion()
            unit.loadFactoryPreset(distortion.flavor.factoryPreset)
            unit.wetDryMix = distortion.wetDryMix
            units.append(unit)
        }
        if let reverb = recipe.reverb {
            let unit = AVAudioUnitReverb()
            unit.loadFactoryPreset(reverb.flavor.factoryPreset)
            unit.wetDryMix = reverb.wetDryMix
            units.append(unit)
        }

        // `engine.connect` raises an Objective-C exception, which Swift cannot catch, when a unit
        // rejects a bus format; asking the units first through `AUAudioUnit` turns that into an
        // error we can degrade on. The reverb only renders stereo, so it gets a stereo output bus
        // and the main mixer folds it back to the mono render format (dry signal at unity gain).
        engine.attach(source)
        units.forEach(engine.attach)
        var previous: AVAudioNode = source
        var previousOutput = format
        for unit in units {
            let unitOutput = unit is AVAudioUnitReverb ? stereo : format
            try Self.validateBusFormats(unit, input: previousOutput, output: unitOutput)
            engine.connect(previous, to: unit, format: previousOutput)
            previous = unit
            previousOutput = unitOutput
        }
        engine.connect(previous, to: engine.mainMixerNode, format: previousOutput)

        self.engine = engine
        sourceNode = source
        effectUnits = units
        self.output = output
        self.fifo = fifo

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCount)
        try engine.start()

        // Calibrate: plenty of zeros in the FIFO, then push-one-frame / render-one-frame exactly as
        // `process` does, and read off how far ahead of the pushes the pulls ran.
        fifo.clear()
        fifo.pushZeros(Self.calibrationPrime, counted: false)
        for _ in 0..<Self.calibrationFrames {
            fifo.pushZeros(frameSamples, counted: true)
            let status = try engine.renderOffline(frameCount, to: output)
            guard status == .success else { throw BuildError.calibrationRender(status) }
        }
        let deficit = fifo.maxDeficit
        engine.reset()
        fifo.clear()
        primeSamplesUnlocked = deficit > 0 ? deficit + frameSamples : 0
        fifo.pushZeros(primeSamplesUnlocked, counted: false)
        unitLatencyMs = units.reduce(0) { $0 + $1.auAudioUnit.latency } * 1_000
    }

    /// Sets the unit's bus formats the way the connections will, reporting a refusal as an error.
    private static func validateBusFormats(_ unit: AVAudioUnit, input: AVAudioFormat,
                                           output: AVAudioFormat) throws {
        try unit.auAudioUnit.inputBusses[0].setFormat(input)
        try unit.auAudioUnit.outputBusses[0].setFormat(output)
    }

    /// One frame through the engine, in place. On failure `samples` keep the raw voice.
    private func render(_ samples: UnsafeMutableBufferPointer<Float>, with engine: AVAudioEngine) {
        guard let fifo, let output else { return }
        let pulledBefore = fifo.totalPulled
        fifo.push(UnsafeBufferPointer(samples))
        var status = AVAudioEngineManualRenderingStatus.error
        var failure: Error?
        do {
            status = try engine.renderOffline(AVAudioFrameCount(frameSamples), to: output)
        } catch {
            failure = error
        }

        if status == .success, Int(output.frameLength) == frameSamples,
           let rendered = output.floatChannelData?[0], let base = samples.baseAddress {
            base.update(from: rendered, count: frameSamples)
            consecutiveRenderFailures = 0
            if fifo.starvations != seenStarvations {
                seenStarvations = fifo.starvations
                if heals < Self.maxHeals {
                    heals += 1
                    fifo.pushZeros(frameSamples, counted: false)
                    primeSamplesUnlocked += frameSamples
                }
                Self.log.warning("voice effect source starved (\(fifo.starvedSamples) samples so far); prime now \(self.primeSamplesUnlocked)")
            }
            return
        }

        if fifo.totalPulled == pulledBefore {
            // Nothing was consumed: take the frame back so a transient failure adds no delay.
            fifo.unpush(frameSamples)
        }
        consecutiveRenderFailures += 1
        if !loggedRenderFailure {
            loggedRenderFailure = true
            let detail = failure.map { String(describing: $0) } ?? "no error"
            Self.log.error("voice effect render failed: status=\(status.rawValue) frames=\(output.frameLength) \(detail, privacy: .public)")
        }
        if consecutiveRenderFailures >= Self.maxConsecutiveRenderFailures {
            Self.log.error("voice effect \(self.effect.rawValue, privacy: .public) gave up after \(self.consecutiveRenderFailures) failed renders; EQ/gain only")
            releaseEngine()
            isEffectAvailable = false
        }
    }

    /// Stops and forgets the engine and its nodes. Idempotent; caller holds `lock` (or is `init`).
    private func releaseEngine() {
        guard let engine else { return }
        engine.stop()
        effectUnits.forEach(engine.detach)
        if let sourceNode { engine.detach(sourceNode) }
        effectUnits = []
        sourceNode = nil
        output = nil
        fifo = nil
        self.engine = nil
    }

    /// Full scale, clamped, rounded to nearest; a non-number becomes silence rather than a click.
    @inline(__always)
    private static func int16(from sample: Float) -> Int16 {
        let scaled = sample * int16Scale
        if scaled.isNaN { return 0 }
        return Int16(min(Float(Int16.max), max(Float(Int16.min), scaled)).rounded())
    }
}

/// The Float ring the offline engine's source node drains, owned and used by one thread at a time
/// (the capture worker, inside `renderOffline`). Besides the samples it keeps the accounting the
/// priming calibration and the starvation diagnostics need: how much was pushed as voice (zeros
/// pushed as prime are not counted, they are delay by design), how much the graph pulled, and the
/// largest lead the pulls ever had over the pushes.
private final class SampleFIFO: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var head = 0
    private(set) var count = 0

    /// Samples pushed as voice (excluding prime and heal zeros).
    private(set) var totalPushed = 0
    /// Samples the graph asked for, including any that had to be zero-filled.
    private(set) var totalPulled = 0
    /// Largest `totalPulled - totalPushed` seen at the end of a pull.
    private(set) var maxDeficit = 0
    private(set) var starvedSamples = 0
    /// Number of pulls that came up short.
    private(set) var starvations = 0
    /// Oldest samples overwritten because the ring was full (should stay 0).
    private(set) var overflowSamples = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Empties the ring and restarts every counter.
    func clear() {
        head = 0
        count = 0
        totalPushed = 0
        totalPulled = 0
        maxDeficit = 0
        starvedSamples = 0
        starvations = 0
        overflowSamples = 0
    }

    func push(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        write(base, count: samples.count)
        totalPushed += samples.count
    }

    /// Queues `n` zeros; `counted` says whether they are voice (a calibration frame) or delay.
    func pushZeros(_ n: Int, counted: Bool) {
        guard n > 0 else { return }
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacity)
            reserve(chunk)
            let start = (head + count) % capacity
            let first = min(chunk, capacity - start)
            (storage + start).update(repeating: 0, count: first)
            if chunk > first { storage.update(repeating: 0, count: chunk - first) }
            count += chunk
            remaining -= chunk
        }
        if counted { totalPushed += n }
    }

    /// Takes back the `n` newest voice samples (a render that consumed nothing).
    func unpush(_ n: Int) {
        let removed = min(max(0, n), count)
        count -= removed
        totalPushed -= min(removed, totalPushed)
    }

    /// Serves `n` samples to `out`, zero-filling (and counting a starvation) when short.
    func pop(into out: UnsafeMutablePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        let available = min(n, count)
        let first = min(available, capacity - head)
        out.update(from: storage + head, count: first)
        if available > first {
            (out + first).update(from: storage, count: available - first)
        }
        if available < n {
            (out + available).update(repeating: 0, count: n - available)
            starvedSamples += n - available
            starvations += 1
        }
        head = (head + available) % capacity
        count -= available
        account(pulled: n)
    }

    /// A pull with nowhere to write: drop the samples so the timeline stays consistent.
    func discard(_ n: Int) {
        guard n > 0 else { return }
        let available = min(n, count)
        head = (head + available) % capacity
        count -= available
        if available < n {
            starvedSamples += n - available
            starvations += 1
        }
        account(pulled: n)
    }

    private func account(pulled n: Int) {
        totalPulled += n
        maxDeficit = max(maxDeficit, totalPulled - totalPushed)
    }

    private func write(_ source: UnsafePointer<Float>, count n: Int) {
        // Only the newest `capacity` samples can fit; anything older is overflow by definition.
        let skip = max(0, n - capacity)
        let chunk = n - skip
        reserve(chunk)
        let start = (head + count) % capacity
        let first = min(chunk, capacity - start)
        (storage + start).update(from: source + skip, count: first)
        if chunk > first {
            storage.update(from: source + skip + first, count: chunk - first)
        }
        count += chunk
        overflowSamples += skip
    }

    /// Makes room for `n` more samples by forgetting the oldest ones if the ring is full.
    private func reserve(_ n: Int) {
        let excess = count + n - capacity
        guard excess > 0 else { return }
        head = (head + excess) % capacity
        count -= excess
        overflowSamples += excess
    }
}

private extension DistortionFlavor {
    var factoryPreset: AVAudioUnitDistortionPreset {
        switch self {
        case .brokenSpeaker: return .multiBrokenSpeaker
        case .decimated: return .multiDecimated2
        case .alienChatter: return .speechAlienChatter
        case .radioTower: return .speechRadioTower
        }
    }
}

private extension ReverbFlavor {
    var factoryPreset: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeHall: return .largeHall
        case .cathedral: return .cathedral
        }
    }
}
