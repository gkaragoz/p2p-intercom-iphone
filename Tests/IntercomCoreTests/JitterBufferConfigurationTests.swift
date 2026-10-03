import XCTest
@testable import IntercomCore

final class JitterBufferConfigurationTests: XCTestCase {
    /// What `AppSettings.jitterConfiguration` computed before wire rates and latency profiles existed.
    private func legacy(targetMs: Double, adaptive: Bool) -> JitterBuffer.Configuration {
        // legacy formula, pinned
        var configuration = JitterBuffer.Configuration.default
        let frames = Int((targetMs / (IntercomProtocol.frameDuration * 1000)).rounded())
        configuration.targetDelayFrames = max(1, frames)
        configuration.adaptiveTarget = adaptive
        configuration.maxDelayFrames = max(configuration.targetDelayFrames + 4, 12)
        return configuration.normalized()
    }

    func testDefaultRateAndProfileReproduceTheLegacyConfiguration() {
        for targetMs in [20.0, 60, 100, 300] {
            for adaptive in [true, false] {
                let expected = legacy(targetMs: targetMs, adaptive: adaptive)
                XCTAssertEqual(JitterBuffer.Configuration.intercom(targetMs: targetMs, adaptive: adaptive), expected,
                               "target \(targetMs) ms, adaptive \(adaptive): the defaults must not change the buffer")
                XCTAssertEqual(JitterBuffer.Configuration.intercom(targetMs: targetMs, adaptive: adaptive,
                                                                   wireRate: .standard, profile: .balanced), expected,
                               "target \(targetMs) ms, adaptive \(adaptive): explicit standard/balanced is the same thing")
            }
        }
    }

    func testHighestRateAndSafeProfileScaleEveryDerivedValue() {
        let configuration = JitterBuffer.Configuration.intercom(targetMs: 60, adaptive: true, wireRate: .highest, profile: .safe)
        XCTAssertEqual(configuration.frameSize, 640)
        XCTAssertEqual(configuration.sampleRate, 32_000)
        XCTAssertEqual(configuration.crossfadeSamples, 80, "still 2.5 ms at 32 kHz")
        XCTAssertEqual(configuration.targetDelayFrames, 3, "the fixed target is counted in 20 ms frames whatever the rate")
        XCTAssertTrue(configuration.adaptiveTarget)
        XCTAssertEqual(configuration.playoutDelay.frameSamples, 640, "the estimator follows the buffer's frame size")
        XCTAssertEqual(configuration.playoutDelay.sampleRate, 32_000)
        XCTAssertEqual(configuration.playoutDelay.floorMs, 100)
        XCTAssertEqual(configuration.playoutDelay.ceilingMs, 300)
        XCTAssertEqual(configuration.playoutDelay.marginMs, 20)
        XCTAssertGreaterThanOrEqual(configuration.maxDelayFrames, 17,
                                    "the cap must hold the 300 ms ceiling (15 frames) plus the two frames normalized() adds")
    }

    func testNarrowRateShrinksFrameAndCrossfade() {
        let configuration = JitterBuffer.Configuration.intercom(targetMs: 60, adaptive: false, wireRate: .narrow)
        XCTAssertEqual(configuration.frameSize, 160)
        XCTAssertEqual(configuration.sampleRate, 8_000)
        XCTAssertEqual(configuration.crossfadeSamples, 20, "still 2.5 ms at 8 kHz")
        XCTAssertEqual(configuration.playoutDelay.frameSamples, 160)
        XCTAssertEqual(configuration.playoutDelay.sampleRate, 8_000)
        XCTAssertEqual(configuration.playoutDelay.floorMs, PlayoutDelayEstimator.Configuration.default.floorMs,
                       "the rate alone leaves the balanced profile's bounds untouched")
    }

    func testHighestRateBufferPlaysBackWholeFrames() {
        let configuration = JitterBuffer.Configuration.intercom(targetMs: 60, adaptive: true, wireRate: .highest, profile: .safe)
        let buffer = JitterBuffer(configuration: configuration)
        let frameSize = configuration.frameSize
        XCTAssertEqual(frameSize, 640)
        /// A ramp that differs in every sample and every frame, so a truncated or shifted copy is caught.
        func ramp(_ frame: Int) -> [Int16] {
            (0..<frameSize).map { Int16(truncatingIfNeeded: frame * 1_000 + $0) }
        }
        for frame in 0..<4 {
            let packet = AudioPacket(sequence: UInt16(frame), timestamp: UInt32(frame * frameSize),
                                     codec: .pcm16Mono32k, samples: ramp(frame))
            buffer.push(packet, arrival: MonotonicTime(seconds: 1 + Double(frame) * 0.020))
        }
        XCTAssertEqual(buffer.statistics.received, 4)
        XCTAssertEqual(buffer.statistics.bufferedFrames, 4, "640-sample packets fit the slots whole")
        XCTAssertEqual(buffer.currentState, .buffering, "80 ms queued is below the safe profile's 100 ms floor")

        // The sender stopped short of the target, so the buffer plays what it has once a whole
        // target of silence has gone by; until then every pull is silence.
        var first: [Int16] = []
        var silentPulls = 0
        while first.isEmpty, silentPulls < 100 {
            let chunk = buffer.pull(count: frameSize)
            if chunk.contains(where: { $0 != 0 }) {
                first = chunk
            } else {
                silentPulls += 1
            }
        }
        XCTAssertGreaterThanOrEqual(silentPulls, 5, "the 100 ms floor is five 20 ms pulls of silence")
        XCTAssertEqual(first, ramp(0), "the first 640-sample frame comes back intact")
        XCTAssertEqual(buffer.pull(count: frameSize * 3), ramp(1) + ramp(2) + ramp(3), "and so do the rest, in order")
        XCTAssertEqual(buffer.statistics.played, 4)
        XCTAssertEqual(buffer.statistics.concealed, 0)
    }
}
