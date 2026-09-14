import Foundation
import XCTest
@testable import IntercomCore

/// Drives a real-size `JitterBuffer` (320-sample frames at 16 kHz) on a simulated clock: packets
/// arrive at scripted times and the render callback pulls a fixed number of samples every IO period.
private final class PlayoutSimulator {
    struct Arrival {
        var timeMs: Double
        var packet: AudioPacket
    }

    struct PushRecord {
        var timeMs: Double
        var sequence: UInt16
        var depthMs: Int
        var targetMs: Int
    }

    static let sampleRate = 16_000
    static let frameSize = 320

    let buffer: JitterBuffer
    let pullSize: Int
    private(set) var output: [Int16] = []
    private(set) var pushes: [PushRecord] = []
    /// Simulated time of every pull that dropped at least one voiced frame.
    private(set) var voicedTrimTimesMs: [Double] = []
    /// Simulated time of every pull that ran dry.
    private(set) var underrunTimesMs: [Double] = []
    /// Time of the pull that started playout.
    private(set) var firstPlayoutMs: Double?

    private var actions: [(timeMs: Double, action: (JitterBuffer) -> Void)] = []

    init(configuration: JitterBuffer.Configuration, pullSize: Int) {
        buffer = JitterBuffer(configuration: configuration)
        self.pullSize = pullSize
    }

    func schedule(atMs time: Double, _ action: @escaping (JitterBuffer) -> Void) {
        actions.append((time, action))
        actions.sort { $0.timeMs < $1.timeMs }
    }

    func run(_ arrivals: [Arrival], untilMs end: Double) {
        let ordered = arrivals.enumerated().sorted {
            $0.element.timeMs == $1.element.timeMs ? $0.offset < $1.offset : $0.element.timeMs < $1.element.timeMs
        }.map(\.element)
        let pullPeriodMs = Double(pullSize) * 1000 / Double(Self.sampleRate)
        var arrivalIndex = 0
        var pullIndex = 0
        var actionIndex = 0
        var scratch = [Int16](repeating: 0, count: pullSize)
        while true {
            let nextPull = Double(pullIndex) * pullPeriodMs
            let nextArrival = arrivalIndex < ordered.count ? ordered[arrivalIndex].timeMs : .infinity
            let nextAction = actionIndex < actions.count ? actions[actionIndex].timeMs : .infinity
            let now = min(nextPull, nextArrival, nextAction)
            if now > end { break }
            if nextAction == now {
                actions[actionIndex].action(buffer)
                actionIndex += 1
            } else if nextArrival == now {
                let arrival = ordered[arrivalIndex]
                buffer.push(arrival.packet, arrival: Self.clock(arrival.timeMs))
                let stats = buffer.statistics
                pushes.append(PushRecord(timeMs: now, sequence: arrival.packet.sequence,
                                         depthMs: stats.depthMs, targetMs: stats.targetDelayMs))
                arrivalIndex += 1
            } else {
                let before = buffer.statistics
                scratch.withUnsafeMutableBufferPointer { _ = buffer.pull(into: $0) }
                output.append(contentsOf: scratch)
                let after = buffer.statistics
                if after.trimmed - after.silenceTrimmed > before.trimmed - before.silenceTrimmed {
                    voicedTrimTimesMs.append(now)
                }
                if after.underruns > before.underruns {
                    underrunTimesMs.append(now)
                }
                if firstPlayoutMs == nil, after.played > 0 {
                    firstPlayoutMs = now
                }
                pullIndex += 1
            }
        }
    }

    /// Depth after pushes in `range` (simulated ms).
    func depths(from start: Double, to end: Double = .infinity) -> [Int] {
        pushes.filter { $0.timeMs >= start && $0.timeMs <= end }.map(\.depthMs)
    }

    /// Earliest time from which every later push saw a depth of at most `limitMs`.
    func settledTime(atMost limitMs: Int, after start: Double) -> Double? {
        var candidate: Double?
        for record in pushes where record.timeMs >= start {
            if record.depthMs > limitMs {
                candidate = nil
            } else if candidate == nil {
                candidate = record.timeMs
            }
        }
        return candidate
    }

    static func clock(_ milliseconds: Double) -> MonotonicTime {
        MonotonicTime(nanoseconds: UInt64((10_000 + milliseconds) * 1_000_000))
    }

    // MARK: Signals

    /// A 430 Hz tone at about −12 dBFS whose phase is continuous across frames (430 Hz does not fit
    /// a whole number of cycles into 20 ms, so dropping a frame without a crossfade clicks), or
    /// near-silence (about −80 dBFS).
    static func frame(sequence: Int, voiced: Bool) -> [Int16] {
        (0..<frameSize).map { index in
            guard voiced else { return Int16(index % 5 - 2) }
            let position = Double(sequence * frameSize + index)
            return Int16((sin(2 * Double.pi * 430 * position / Double(sampleRate)) * 8_000).rounded())
        }
    }

    /// Speech-like: 200 ms of voice, 100 ms of pause.
    static func speechLike(_ sequence: Int) -> Bool {
        sequence % 15 < 10
    }

    /// One packet per 20 ms of capture, arriving `delayMs(sequence)` after capture (plus a fixed 0.5 ms).
    /// `periodMs` models the sender's clock rate.
    static func arrivals(count: Int, periodMs: Double = 20,
                         voiced: (Int) -> Bool = speechLike,
                         delayMs: (Int, Double) -> Double = { _, _ in 0 }) -> [Arrival] {
        (0..<count).map { sequence in
            let capture = Double(sequence) * periodMs
            let packet = AudioPacket(sequence: UInt16(truncatingIfNeeded: sequence),
                                     timestamp: UInt32(truncatingIfNeeded: sequence * frameSize),
                                     samples: frame(sequence: sequence, voiced: voiced(sequence)))
            return Arrival(timeMs: capture + 0.5 + delayMs(sequence, capture), packet: packet)
        }
    }

    /// Nothing arrives during `start..<start+duration`; the delayed packets all land at the end.
    static func stall(startMs: Double, durationMs: Double) -> (Int, Double) -> Double {
        { _, capture in
            capture >= startMs && capture < startMs + durationMs ? startMs + durationMs - capture : 0
        }
    }

    static func manual(targetFrames: Int) -> JitterBuffer.Configuration {
        var config = JitterBuffer.Configuration()
        config.targetDelayFrames = targetFrames
        config.maxDelayFrames = max(targetFrames + 4, 12)
        return config
    }

    static func adaptive() -> JitterBuffer.Configuration {
        var config = JitterBuffer.Configuration()
        config.adaptiveTarget = true
        return config
    }
}

final class JitterBufferPlayoutTests: XCTestCase {
    // MARK: Ratchet fix

    func testStallThenSteadyArrivalsReturnsToTargetWithinOneSecond() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 3), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 250, delayMs: PlayoutSimulator.stall(startMs: 2_000, durationMs: 100)),
                untilMs: 5_000)

        XCTAssertEqual(Set(sim.depths(from: 500, to: 1_990)), [60], "steady state sits exactly at the target")
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertGreaterThan(sim.depths(from: 2_100, to: 2_150).max() ?? 0, 60, "the stall left extra delay behind")
        guard let settled = sim.settledTime(atMost: 60, after: 2_100) else {
            return XCTFail("delay never returned to the target")
        }
        XCTAssertLessThanOrEqual(settled - 2_100, 1_000)
        XCTAssertEqual(Set(sim.depths(from: settled)), [60], "and it does not undershoot either")
        XCTAssertEqual(stats.silenceTrimmed, stats.trimmed, "speech pauses were enough; no voiced frame was cut")
        XCTAssertEqual(stats.concealed, 0)
    }

    func testTrimmingBehavesIdenticallyAtPullSizes80_160_320() {
        var outcomes: [(trimmed: Int, underruns: Int, settledMs: Double, finalDepths: Set<Int>)] = []
        for pullSize in [80, 160, 320] {
            let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 3), pullSize: pullSize)
            sim.run(PlayoutSimulator.arrivals(count: 250, delayMs: PlayoutSimulator.stall(startMs: 2_000, durationMs: 100)),
                    untilMs: 5_000)
            let stats = sim.buffer.statistics
            let settled = sim.settledTime(atMost: 60, after: 2_100) ?? .infinity
            outcomes.append((stats.trimmed, stats.underruns, settled, Set(sim.depths(from: 4_000))))
        }
        for outcome in outcomes.dropFirst() {
            XCTAssertEqual(outcome.trimmed, outcomes[0].trimmed)
            XCTAssertEqual(outcome.underruns, outcomes[0].underruns)
            XCTAssertEqual(outcome.finalDepths, outcomes[0].finalDepths)
            XCTAssertEqual(outcome.settledMs, outcomes[0].settledMs, accuracy: 60)
        }
        XCTAssertEqual(outcomes[0].finalDepths, [60])
    }

    func testEndOfBurstLossDoesNotRatchet() {
        // Talk spurts of 1 s separated by 500 ms pauses; the last packet of every spurt is lost.
        var arrivals: [PlayoutSimulator.Arrival] = []
        var sequence = 0
        for spurt in 0..<8 {
            let startMs = Double(spurt) * 1_500
            for index in 0..<50 {
                let captureMs = startMs + Double(index) * 20
                let isLast = index == 49
                let packet = AudioPacket(sequence: UInt16(sequence), timestamp: UInt32(captureMs * 16),
                                         samples: PlayoutSimulator.frame(sequence: sequence, voiced: true))
                sequence += 1
                if !isLast {
                    arrivals.append(.init(timeMs: captureMs + 0.5, packet: packet))
                }
            }
        }
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 3), pullSize: 160)
        sim.run(arrivals, untilMs: 12_000)
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.skippedOnResume, 7)
        XCTAssertEqual(stats.concealed, 0)
        XCTAssertEqual(stats.underruns, 8)
        XCTAssertEqual(Set(sim.depths(from: 100)).max(), 60, "every spurt starts at the target, none deeper")
    }

    func testSpurtShorterThanTheTargetPlaysOneTargetLate() {
        // A 140 ms push-to-talk tap against a 160 ms target: the queue never reaches the target.
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 8), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 7, voiced: { _ in true }), untilMs: 1_000)
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.played, 7)
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertEqual(stats.bufferedFrames, 0)
        // Last packet at 120.5 ms; 160 ms of pulled silence later the queue starts playing.
        XCTAssertEqual(sim.firstPlayoutMs ?? 0, 290, accuracy: 10)
    }

    // MARK: Silent first, voiced rate-limited

    func testOneFrameOfExcessWaitsForSilence() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 4), pullSize: 160)
        sim.schedule(atMs: 1_000) { buffer in
            var config = buffer.configuration
            config.targetDelayFrames = 3
            buffer.configuration = config
        }
        sim.run(PlayoutSimulator.arrivals(count: 250, voiced: { $0 < 150 }), untilMs: 5_000)

        XCTAssertEqual(Set(sim.depths(from: 1_100, to: 2_990)), [80], "one frame too deep, but only voice to cut")
        XCTAssertTrue(sim.voicedTrimTimesMs.isEmpty)
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.trimmed, 1)
        XCTAssertEqual(stats.silenceTrimmed, 1)
        guard let settled = sim.settledTime(atMost: 60, after: 3_000) else {
            return XCTFail("the silent frame was not dropped")
        }
        XCTAssertLessThan(settled, 3_200)
    }

    func testSilentFramesAreDroppedBeforeVoicedOnes() {
        // Two frames of excess and a pause every 300 ms: the pauses absorb everything well before
        // the voiced patience (1 s) runs out.
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 5), pullSize: 160)
        sim.schedule(atMs: 1_000) { buffer in
            var config = buffer.configuration
            config.targetDelayFrames = 3
            buffer.configuration = config
        }
        sim.run(PlayoutSimulator.arrivals(count: 200), untilMs: 4_000)
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.trimmed, 2)
        XCTAssertEqual(stats.silenceTrimmed, 2)
        XCTAssertTrue(sim.voicedTrimTimesMs.isEmpty)
        XCTAssertEqual(Set(sim.depths(from: 2_000)), [60])
    }

    func testVoicedDropsAreRateLimitedAndStopBelowTwoFramesOfExcess() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 7), pullSize: 160)
        sim.schedule(atMs: 1_000) { buffer in
            var config = buffer.configuration
            config.targetDelayFrames = 3
            buffer.configuration = config
        }
        sim.run(PlayoutSimulator.arrivals(count: 300, voiced: { _ in true }), untilMs: 6_000)

        let drops = sim.voicedTrimTimesMs
        XCTAssertEqual(drops.count, 3, "excess 4 frames: voiced drops stop once fewer than 2 remain")
        guard let first = drops.first else { return }
        XCTAssertGreaterThanOrEqual(first, 2_000, "two frames of excess must persist for 1 s first")
        XCTAssertLessThan(first, 2_100)
        for (earlier, later) in zip(drops, drops.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 200)
        }
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.silenceTrimmed, 0)
        XCTAssertEqual(stats.underruns, 0)
        XCTAssertEqual(Set(sim.depths(from: 3_000)), [80])
    }

    func testVoicedDropIsCrossfaded() {
        func maximumStep(crossfade: Int) -> Int {
            var config = PlayoutSimulator.manual(targetFrames: 7)
            config.crossfadeSamples = crossfade
            let sim = PlayoutSimulator(configuration: config, pullSize: 160)
            sim.schedule(atMs: 1_000) { buffer in
                var config = buffer.configuration
                config.targetDelayFrames = 3
                buffer.configuration = config
            }
            sim.run(PlayoutSimulator.arrivals(count: 200, voiced: { _ in true }), untilMs: 3_500)
            XCTAssertGreaterThan(sim.buffer.statistics.trimmed, 0)
            let start = Int((sim.firstPlayoutMs ?? 0) * 16) + 320
            var largest = 0
            for index in (start + 1)..<sim.output.count {
                largest = max(largest, abs(Int(sim.output[index]) - Int(sim.output[index - 1])))
            }
            return largest
        }
        // A 430 Hz tone at amplitude 8000 moves at most ~1350 per sample.
        XCTAssertGreaterThan(maximumStep(crossfade: 0), 4_000, "without a crossfade the cut is a click")
        XCTAssertLessThan(maximumStep(crossfade: 40), 1_800)
    }

    // MARK: Clock skew

    func testFastSenderClockIsTrimmedWithoutUnderruns() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 3), pullSize: 160)
        // 1000 ppm fast: one extra frame every 20 s.
        sim.run(PlayoutSimulator.arrivals(count: 3_000, periodMs: 19.98), untilMs: 59_900)
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.underruns, 0, "underruns at \(sim.underrunTimesMs)")
        XCTAssertGreaterThanOrEqual(stats.trimmed, 2)
        XCTAssertEqual(stats.silenceTrimmed, stats.trimmed)
        XCTAssertLessThanOrEqual(sim.depths(from: 1_000).max() ?? .max, 80, "never more than one frame above the target")
    }

    func testSlowSenderClockUnderrunsRarelyAndNeverRatchets() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.manual(targetFrames: 3), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 3_000, periodMs: 20.02), untilMs: 60_000)
        let stats = sim.buffer.statistics
        XCTAssertLessThanOrEqual(stats.underruns, 2, "underruns at \(sim.underrunTimesMs)")
        XCTAssertEqual(stats.trimmed, 0)
        XCTAssertLessThanOrEqual(sim.depths(from: 1_000).max() ?? .max, 60)
    }

    func testAdaptiveTargetIsNotInflatedBySkew() {
        for period in [19.99, 20.01] {
            let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
            sim.run(PlayoutSimulator.arrivals(count: 2_000, periodMs: period), untilMs: 40_000)
            XCTAssertLessThanOrEqual(sim.pushes.map(\.targetMs).max() ?? .max, 45, "period \(period)")
        }
    }

    // MARK: Adaptive target

    func testAdaptiveTargetStaysAtTheFloorOnACleanLink() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 500), untilMs: 10_000)
        XCTAssertEqual(Set(sim.pushes.map(\.targetMs)), [40])
        XCTAssertEqual(sim.buffer.statistics.underruns, 0)
        XCTAssertEqual(Set(sim.depths(from: 1_000)), [40])
    }

    func testAdaptiveTargetGrowsWithJitterAndDecaysWhenItStops() {
        var rng = SplitMix64(seed: 7)
        let jitter: [Double] = (0..<1_500).map { _ in Double.random(in: 0...30, using: &rng) }
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
        // 20 s of 0...30 ms random delay, then 10 s of a clean link.
        sim.run(PlayoutSimulator.arrivals(count: 1_500, delayMs: { sequence, _ in sequence < 1_000 ? jitter[sequence] : 0 }),
                untilMs: 30_000)
        let jitteryTargets = sim.pushes.filter { $0.timeMs > 5_000 && $0.timeMs < 20_000 }.map(\.targetMs)
        XCTAssertGreaterThanOrEqual(jitteryTargets.min() ?? 0, 60)
        XCTAssertLessThanOrEqual(jitteryTargets.max() ?? .max, 80)
        XCTAssertEqual(sim.underrunTimesMs.filter { $0 > 5_000 }, [], "30 ms of jitter is fully covered")
        XCTAssertEqual(sim.pushes.last?.targetMs, 40, "back to the floor once the jitter is gone")
    }

    func testAdaptiveTargetAfterAStallGrowsThenReturnsToTheFloor() {
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 500, delayMs: PlayoutSimulator.stall(startMs: 2_000, durationMs: 100)),
                untilMs: 10_000)
        XCTAssertEqual(Set(sim.depths(from: 500, to: 1_990)), [40])
        XCTAssertEqual(sim.pushes.first { $0.timeMs >= 2_100 }?.targetMs ?? 0, 140, accuracy: 3, "fast growth")
        XCTAssertEqual(sim.buffer.statistics.underruns, 1)
        guard let settled = sim.settledTime(atMost: 40, after: 2_100) else {
            return XCTFail("delay never returned to the floor")
        }
        XCTAssertLessThanOrEqual(settled, 8_000, "decays within about one window")
        XCTAssertEqual(Set(sim.depths(from: settled)), [40])
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.silenceTrimmed, stats.trimmed, "the decay only ever cut pauses")
        XCTAssertEqual(stats.concealed, 0)
    }

    func testAdaptiveTargetAbsorbsPeriodicBursts() {
        // Packets are held back and delivered five at a time every 100 ms.
        let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
        sim.run(PlayoutSimulator.arrivals(count: 1_000, delayMs: { sequence, _ in Double(4 - sequence % 5) * 20 }),
                untilMs: 19_900)
        // 80 ms extra delay for the first packet of each burst + frame + pull + margin.
        XCTAssertEqual(Set(sim.pushes.filter { $0.timeMs > 1_000 }.map(\.targetMs)), [120])
        XCTAssertEqual(sim.underrunTimesMs.filter { $0 > 1_000 }, [], "once the target covers the bursts, playout never runs dry")
        XCTAssertLessThanOrEqual(sim.depths(from: 1_000).max() ?? .max, 200)
    }

    // MARK: Voice-activation pre-roll end to end

    func testVoicePreRollDoesNotInflateTheAdaptiveTargetAndItsDepthIsAbsorbed() {
        // Sender: 1 s of voice, 1 s of silence, voice activation with a 100 ms hangover and 2 frames of pre-roll.
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -38, hangoverFrames: 5))
        var packetizer = AudioPacketizer(preRollCapacity: gate.preRollFrames)
        var arrivals: [PlayoutSimulator.Arrival] = []
        var preRolls = 0
        for capture in 0..<500 {
            let voiced = capture % 100 < 50
            let decision = gate.evaluate(levelDB: voiced ? -12 : -80)
            if decision.preRollFrames > 0 { preRolls += 1 }
            let captureMs = Double(capture) * 20
            for packet in packetizer.process(PlayoutSimulator.frame(sequence: capture, voiced: voiced), decision: decision) {
                arrivals.append(.init(timeMs: captureMs + 0.5, packet: packet))
            }
        }
        XCTAssertEqual(preRolls, 4, "every spurt after the first opens with pre-roll")

        let sim = PlayoutSimulator(configuration: PlayoutSimulator.adaptive(), pullSize: 160)
        sim.run(arrivals, untilMs: 10_000)
        XCTAssertEqual(Set(sim.pushes.map(\.targetMs)), [40], "pre-roll bursts are recognised as talk-spurt starts, not jitter")
        let stats = sim.buffer.statistics
        XCTAssertEqual(stats.concealed, 0)
        XCTAssertEqual(stats.silenceTrimmed, stats.trimmed, "only silence was cut")
        for spurt in 1..<5 {
            let start = Double(spurt) * 2_000
            let depths = sim.depths(from: start, to: start + 1_100)
            XCTAssertEqual(depths.first(where: { $0 > 40 }), 60, "spurt \(spurt) starts one frame deep (pre-roll)")
            XCTAssertEqual(sim.depths(from: start + 1_060, to: start + 1_100).max(), 40,
                           "spurt \(spurt): the extra frame goes with the first silent hangover frame")
        }
    }
}
