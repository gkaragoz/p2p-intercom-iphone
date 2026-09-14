import Foundation
import XCTest
@testable import IntercomCore

final class PlayoutDelayEstimatorTests: XCTestCase {
    /// Feeds packets captured every 20 ms; `delay` returns the network delay of each packet in ms.
    /// Packets are recorded in arrival order.
    @discardableResult
    private func feed(_ estimator: inout PlayoutDelayEstimator, count: Int, firstSequence: Int = 0,
                      captureStartMs: Double = 0, periodMs: Double = 20,
                      timestampOffset: UInt32 = 0,
                      delay: (Int) -> Double) -> [Double] {
        var packets: [(arrival: Double, sequence: Int, capture: Double)] = []
        for index in 0..<count {
            let capture = captureStartMs + Double(index) * periodMs
            packets.append((capture + 5 + delay(index), firstSequence + index, capture))
        }
        packets.sort { $0.arrival == $1.arrival ? $0.sequence < $1.sequence : $0.arrival < $1.arrival }
        return packets.map { packet in
            let timestamp = timestampOffset &+ UInt32(truncatingIfNeeded: Int64((packet.capture * 16).rounded()))
            return estimator.record(sequence: UInt16(truncatingIfNeeded: packet.sequence),
                                    timestamp: timestamp,
                                    arrival: MonotonicTime(nanoseconds: UInt64((50_000 + packet.arrival) * 1_000_000)))
        }
    }

    func testStartsAtTheFloor() {
        let estimator = PlayoutDelayEstimator()
        XCTAssertEqual(estimator.targetMs, 40)
        XCTAssertEqual(estimator.delayMs, 0)
    }

    func testConstantTransitGivesTheFloor() {
        var estimator = PlayoutDelayEstimator()
        let delays = feed(&estimator, count: 500) { _ in 37 }
        XCTAssertEqual(delays.max(), 0)
        XCTAssertEqual(estimator.delayMs, 0)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testUniformJitterIsCoveredWithTheMargin() {
        var rng = SplitMix64(seed: 42)
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 1_000) { _ in Double.random(in: -5...5, using: &rng) }
        // ±5 ms → up to 10 ms extra delay; + 20 frame + 10 pull + 10 margin.
        XCTAssertEqual(estimator.quantileDelayMs, 10, accuracy: 1.5)
        XCTAssertEqual(estimator.targetMs, 50, accuracy: 1.5)
    }

    func testPeriodicBurstsOfFivePackets() {
        var estimator = PlayoutDelayEstimator()
        // Held back and released together every 100 ms: 80, 60, 40, 20, 0 ms late.
        feed(&estimator, count: 1_000) { Double(4 - $0 % 5) * 20 }
        XCTAssertEqual(estimator.quantileDelayMs, 80)
        XCTAssertEqual(estimator.targetMs, 120)
    }

    func testRareSpikesGrowTheTargetImmediatelyAndHoldIt() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 300) { _ in 0 }
        XCTAssertEqual(estimator.targetMs, 40)

        // One packet 80 ms late: the p95 alone would never notice.
        feed(&estimator, count: 1, firstSequence: 300, captureStartMs: 6_000) { _ in 80 }
        XCTAssertEqual(estimator.quantileDelayMs, 0)
        XCTAssertEqual(estimator.targetMs, 120, "fast growth")

        // An 80 ms spike every second (1 in 50 packets) keeps the target up.
        var targets: [Double] = []
        for second in 0..<10 {
            feed(&estimator, count: 50, firstSequence: 301 + second * 50, captureStartMs: 6_020 + Double(second) * 1_000) {
                $0 == 49 ? 80 : 0
            }
            targets.append(estimator.targetMs)
        }
        XCTAssertGreaterThanOrEqual(targets.min() ?? 0, 100)
        XCTAssertLessThanOrEqual(targets.max() ?? .infinity, 120)
    }

    func testTargetDecaysToTheFloorWithinOneWindowAfterSpikesStop() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 500) { $0 % 50 == 49 ? 80 : 0 }
        XCTAssertGreaterThan(estimator.targetMs, 100)
        var history: [Double] = []
        for block in 0..<5 {
            feed(&estimator, count: 50, firstSequence: 500 + block * 50, captureStartMs: 10_000 + Double(block) * 1_000) { _ in 0 }
            history.append(estimator.targetMs)
        }
        XCTAssertEqual(history.last, 40, "250 clean packets = one window")
        XCTAssertEqual(history, history.sorted(by: >), "slow, monotonic decay")
        XCTAssertGreaterThan(history.first ?? 0, 40)
    }

    func testTalkSpurtPauseReanchorsInsteadOfCountingAsDelay() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 100) { _ in 0 }
        XCTAssertEqual(estimator.spurtCount, 1)
        // Sender paused for 3 s (its sample clock kept running). Measured against the old anchor the
        // first packets of the next spurt would be 30 and 15 ms late; they arrive in order.
        let delays = feed(&estimator, count: 100, firstSequence: 100, captureStartMs: 5_000) { [30, 15][safe: $0] ?? 0 }
        XCTAssertEqual(estimator.spurtCount, 2)
        XCTAssertEqual(delays.prefix(3), [0, 0, 0], "the first packet of a spurt defines the new anchor")
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testPreRollBurstAtSpurtStartIsNotJitter() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 100) { _ in 0 }
        // Voice activation opens at 5 s: two pre-roll frames captured 40 and 20 ms earlier go out
        // together with the current one.
        feed(&estimator, count: 50, firstSequence: 100, captureStartMs: 4_960) { index in
            index < 2 ? Double(40 - index * 20) : 0
        }
        XCTAssertEqual(estimator.spurtCount, 2)
        XCTAssertEqual(estimator.delayMs, 0)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testArrivalGapReanchorsSendersWhoseClockPauses() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 100) { _ in 0 }
        // Contiguous timestamps, but 1 s of nothing in between (an older sender's clock).
        let delays = feed(&estimator, count: 50, firstSequence: 100, captureStartMs: 2_000) { _ in 1_000 }
        XCTAssertEqual(estimator.spurtCount, 2)
        XCTAssertEqual(delays.max(), 0)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testNetworkStallShorterThanTheSpurtGapCountsAsDelay() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 100) { _ in 0 }
        // 100 ms stall: the delayed packets are delivered together with the first on-time one.
        let delays = feed(&estimator, count: 6, firstSequence: 100, captureStartMs: 2_000) { index in
            Double(100 - index * 20)
        }
        XCTAssertEqual(estimator.spurtCount, 1)
        XCTAssertEqual(delays.max() ?? 0, 100, accuracy: 0.5)
        // 100 ms + frame + pull + margin, less the first 5 of 250 steps of the peak's linear decay.
        XCTAssertEqual(estimator.targetMs, 138, accuracy: 0.5, "grows at once to cover a repeat")

        // Then the link is clean again: the peak decays over one window (250 packets).
        var targets: [Double] = []
        for block in 0..<5 {
            feed(&estimator, count: 50, firstSequence: 106 + block * 50, captureStartMs: 2_120 + Double(block) * 1_000) { _ in 0 }
            targets.append(estimator.targetMs)
        }
        XCTAssertEqual(targets[0], 118, accuracy: 0.5)
        XCTAssertEqual(targets, targets.sorted(by: >))
        XCTAssertEqual(targets.last, 40)
    }

    func testLastingBaseDelayStepIsAbsorbedQuickly() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 300) { _ in 0 }
        // The path gets 30 ms slower for good (e.g. migration to another interface), without a
        // sample-clock jump or an arrival gap long enough to start a spurt.
        let delays = feed(&estimator, count: 600, firstSequence: 300, captureStartMs: 6_000) { _ in 30 }
        XCTAssertEqual(estimator.spurtCount, 1)
        XCTAssertEqual(delays[0], 30, accuracy: 0.5, "the step is jitter at first")
        XCTAssertEqual(delays[99], 28, accuracy: 0.5, "the anchor drift alone is far too slow")
        let absorbed = delays.firstIndex { $0 < 0.01 } ?? .max
        XCTAssertLessThanOrEqual(absorbed, 200, "within two recovery blocks it is the new base")
        XCTAssertEqual(delays[absorbed...].max() ?? .infinity, 0, accuracy: 0.01)
        XCTAssertEqual(estimator.targetMs, 40, "and after one more window the target is back at the floor")
    }

    func testAnchorRecoveryIgnoresJitterWithFastPackets() {
        var rng = SplitMix64(seed: 3)
        var estimator = PlayoutDelayEstimator()
        // 0...40 ms of jitter, but the fastest packets keep defining the base.
        let delays = feed(&estimator, count: 2_000) { index in
            index % 10 == 0 ? 0 : Double.random(in: 0...40, using: &rng)
        }
        XCTAssertEqual(delays.suffix(250).max() ?? 0, 40, accuracy: 1)
        XCTAssertEqual(estimator.quantileDelayMs, 38, accuracy: 2)
    }

    func testSequenceAndTimestampWrapAround() {
        var estimator = PlayoutDelayEstimator()
        let delays = feed(&estimator, count: 400, firstSequence: 65_336, timestampOffset: UInt32.max - 32_000) { _ in 0 }
        XCTAssertEqual(delays.max(), 0)
        XCTAssertEqual(estimator.spurtCount, 1)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testReorderedPacketCountsItsLateness() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 100) { _ in 0 }
        // Packet 100 arrives 45 ms late, after 101 and 102.
        let delays = feed(&estimator, count: 10, firstSequence: 100, captureStartMs: 2_000) { $0 == 0 ? 45 : 0 }
        XCTAssertEqual(delays.max() ?? 0, 45, accuracy: 0.5)
        XCTAssertEqual(estimator.spurtCount, 1)
    }

    func testSenderRestartDoesNotLookLikeDelay() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 300, firstSequence: 20_000, timestampOffset: 900_000) { _ in 0 }
        // The peer app restarted: sequence and sample clock start again from zero.
        let delays = feed(&estimator, count: 100, firstSequence: 0, captureStartMs: 6_200) { _ in 0 }
        XCTAssertEqual(delays.max(), 0)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testClockSkewWithinTheDriftIsNotMistakenForJitter() {
        for ppm in [-500.0, 500.0] {
            var estimator = PlayoutDelayEstimator()
            // Sender clock off by `ppm`: arrivals drift against the timestamps for 2 minutes.
            let delays = feed(&estimator, count: 6_000, periodMs: 20 * (1 + ppm / 1_000_000)) { _ in 0 }
            XCTAssertLessThan(delays.max() ?? .infinity, 1.5, "\(ppm) ppm")
            XCTAssertEqual(estimator.targetMs, 40, accuracy: 1.5, "\(ppm) ppm")
        }
    }

    func testPullQuantumAndCeiling() {
        var estimator = PlayoutDelayEstimator()
        feed(&estimator, count: 300) { Double(4 - $0 % 5) * 20 }
        estimator.pullQuantumMs = 21.3
        XCTAssertEqual(estimator.targetMs, 131.3, accuracy: 0.001)
        // Contiguous sample clock, but a 5 s arrival gap: a new spurt, not 5 s of delay.
        let delays = feed(&estimator, count: 1, firstSequence: 300, captureStartMs: 6_000) { _ in 5_000 }
        XCTAssertEqual(delays, [0])
        XCTAssertEqual(estimator.spurtCount, 2)
        XCTAssertLessThanOrEqual(estimator.targetMs, 200)
        estimator.reset()
        XCTAssertEqual(estimator.targetMs, 51.3, accuracy: 0.001, "clean link: frame + observed pull + margin")
        XCTAssertEqual(estimator.pullQuantumMs, 21.3, "reset keeps the observed IO size")
        XCTAssertEqual(estimator.packetCount, 0)
        XCTAssertEqual(estimator.spurtCount, 0)
    }

    func testCeilingClampsLargeSteadyDelay() {
        var estimator = PlayoutDelayEstimator()
        // Bursts of 12 packets every 240 ms (just below the spurt gap): 220 ms of extra delay for
        // the first packet of each.
        let delays = feed(&estimator, count: 1_200) { Double(11 - $0 % 12) * 20 }
        XCTAssertEqual(estimator.spurtCount, 1)
        XCTAssertEqual(delays.max() ?? 0, 220, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(estimator.quantileDelayMs, 200, "the histogram saturates at the ceiling")
        XCTAssertEqual(estimator.targetMs, 200)
    }

    func testClockSkewAtExactlyTheDriftRateDoesNotCreepIntoTheFirstBin() {
        var estimator = PlayoutDelayEstimator()
        // 1000 ppm slow sender: transit grows by exactly the anchor drift per packet.
        let delays = feed(&estimator, count: 3_000, periodMs: 20.02) { _ in 0 }
        XCTAssertLessThan(delays.max() ?? .infinity, 0.01)
        XCTAssertEqual(estimator.quantileDelayMs, 0)
        XCTAssertEqual(estimator.targetMs, 40)
    }

    func testConfigurationIsNormalized() {
        var config = PlayoutDelayEstimator.Configuration()
        config.floorMs = -3
        config.ceilingMs = .nan
        config.quantile = 7
        config.windowPackets = 0
        config.sampleRate = 0
        config.spurtGapMs = 1
        config.anchorRecoveryPackets = -5
        config.anchorDriftMsPerPacket = .infinity
        let normalized = config.normalized()
        XCTAssertEqual(normalized.floorMs, 0)
        XCTAssertEqual(normalized.ceilingMs, 200)
        XCTAssertEqual(normalized.quantile, 1)
        XCTAssertEqual(normalized.windowPackets, 1)
        XCTAssertEqual(normalized.sampleRate, 1)
        XCTAssertEqual(normalized.spurtGapMs, normalized.frameMs)
        XCTAssertEqual(normalized.anchorRecoveryPackets, 0)
        XCTAssertEqual(normalized.anchorDriftMsPerPacket, 0)
        var estimator = PlayoutDelayEstimator(configuration: config)
        estimator.record(sequence: 0, timestamp: 0, arrival: .zero)
        estimator.record(sequence: 1, timestamp: 1, arrival: MonotonicTime(seconds: 1))
        XCTAssertLessThanOrEqual(estimator.targetMs, 200)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
