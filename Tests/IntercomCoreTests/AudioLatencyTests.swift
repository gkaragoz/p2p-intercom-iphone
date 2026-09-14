import Foundation
import XCTest
@testable import IntercomCore

final class AudioLatencyTests: XCTestCase {
    func testFirstSampleHasWindowValuesButNoRates() {
        var sampler = AudioLatencySampler()
        var reading = AudioCounterReading()
        reading.captureCallbacks = 100
        reading.windowCaptureFramesMin = 480
        reading.windowCaptureFramesMax = 512
        reading.windowCaptureMaxIntervalNs = 12_500_000
        let snapshot = sampler.sample(reading: reading, jitter: JitterBuffer.Statistics(), context: .init(),
                                      now: MonotonicTime(seconds: 10))
        XCTAssertEqual(snapshot.captureFramesPerCallbackMin, 480)
        XCTAssertEqual(snapshot.captureFramesPerCallbackMax, 512)
        XCTAssertEqual(snapshot.maxCaptureIntervalMs, 12.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.captureCallbacksPerSecond, 0)
    }

    func testRatesAndAveragesFromDeltas() {
        var sampler = AudioLatencySampler()
        var first = AudioCounterReading()
        first.captureCallbacks = 1_000
        first.captureFrames = 480_000
        first.deliveryLagSumNs = 5_000_000_000
        first.deliveryLagCount = 1_000
        first.deliveredFrames = 500
        var jitter = JitterBuffer.Statistics()
        jitter.underruns = 3
        jitter.lateDropped = 1
        jitter.renderLockMisses = 2
        _ = sampler.sample(reading: first, jitter: jitter, context: .init(), now: MonotonicTime(seconds: 1))

        var second = first
        second.captureCallbacks += 200
        second.captureFrames += 200 * 480
        second.deliveryLagSumNs += 200 * 3_000_000
        second.deliveryLagCount += 200
        second.deliveredFrames += 100
        second.renderCallbacks = 400
        second.windowDeliveryLagMaxNs = 4_500_000
        var jitterAfter = jitter
        jitterAfter.underruns = 5
        jitterAfter.lateDropped = 2
        jitterAfter.overflowDropped = 2
        jitterAfter.renderLockMisses = 2
        jitterAfter.targetDelayMs = 40
        jitterAfter.depthMs = 38
        let snapshot = sampler.sample(reading: second, jitter: jitterAfter, context: .init(), now: MonotonicTime(seconds: 3))
        XCTAssertEqual(snapshot.captureCallbacksPerSecond, 100, accuracy: 1e-9)
        XCTAssertEqual(snapshot.captureFramesPerCallbackAverage, 480, accuracy: 1e-9)
        XCTAssertEqual(snapshot.deliveryLagAverageMs, 3, accuracy: 1e-9)
        XCTAssertEqual(snapshot.deliveryLagMaxMs, 4.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.framesDeliveredPerSecond, 50, accuracy: 1e-9)
        XCTAssertEqual(snapshot.renderCallbacksPerSecond, 200, accuracy: 1e-9)
        XCTAssertEqual(snapshot.underrunsPerSecond, 1, accuracy: 1e-9)
        XCTAssertEqual(snapshot.latePerSecond, 1.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.lockMissesPerSecond, 0)
        XCTAssertEqual(snapshot.jitterTargetMs, 40)
        XCTAssertEqual(snapshot.jitterDepthMs, 38)
    }

    func testCountersThatWentBackwardsCountAsFreshStart() {
        var sampler = AudioLatencySampler()
        var first = AudioCounterReading()
        first.captureCallbacks = 5_000
        var jitter = JitterBuffer.Statistics()
        jitter.underruns = 10
        _ = sampler.sample(reading: first, jitter: jitter, context: .init(), now: MonotonicTime(seconds: 1))
        var second = AudioCounterReading()
        second.captureCallbacks = 50
        let snapshot = sampler.sample(reading: second, jitter: JitterBuffer.Statistics(), context: .init(),
                                      now: MonotonicTime(seconds: 2))
        XCTAssertEqual(snapshot.captureCallbacksPerSecond, 50, accuracy: 1e-9)
        XCTAssertEqual(snapshot.underrunsPerSecond, 0)
    }

    func testMouthToEarEstimate() {
        var snapshot = AudioLatencySnapshot()
        XCTAssertNil(snapshot.estimatedMouthToEarMs, "nothing to estimate before audio runs")
        snapshot.capturePath = .sinkNode
        snapshot.session.ioBufferDuration = 0.010
        snapshot.session.inputLatency = 0.002
        snapshot.session.outputLatency = 0.005
        snapshot.deliveryLagAverageMs = 13
        snapshot.jitterTargetMs = 40
        XCTAssertEqual(snapshot.estimatedMouthToEarMs ?? 0, 2 + 13 + 40 + 10 + 5, accuracy: 1e-9)
        snapshot.roundTripMs = 8
        XCTAssertEqual(snapshot.estimatedMouthToEarMs ?? 0, 74, accuracy: 1e-9)
        XCTAssertTrue(snapshot.logLine.contains("capture=sink"))
        XCTAssertTrue(snapshot.logLine.contains("m2e=74ms"))
        XCTAssertTrue(snapshot.logLine.contains("rtt=8ms"))
    }
}
