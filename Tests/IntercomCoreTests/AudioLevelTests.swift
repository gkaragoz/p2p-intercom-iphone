import XCTest
@testable import IntercomCore

final class AudioLevelTests: XCTestCase {
    func testSilenceIsMinusInfinityFloor() {
        XCTAssertEqual(AudioLevel.rms([Int16](repeating: 0, count: 100)), 0)
        XCTAssertEqual(AudioLevel.decibels(fromLinear: 0), -100)
        XCTAssertEqual(AudioLevel.rms([]), 0)
    }

    func testFullScaleSquareWaveIsZeroDB() {
        let samples: [Int16] = (0..<320).map { $0 % 2 == 0 ? Int16.max : -Int16.max }
        let rms = AudioLevel.rms(samples)
        XCTAssertEqual(rms, 1, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.decibels(fromLinear: rms), 0, accuracy: 0.01)
    }

    func testHalfScaleIsMinusSixDB() {
        XCTAssertEqual(AudioLevel.decibels(fromLinear: 0.5), -6.02, accuracy: 0.01)
    }

    func testMeterValueMapsRange() {
        XCTAssertEqual(AudioLevel.meterValue(dB: -60), 0)
        XCTAssertEqual(AudioLevel.meterValue(dB: 0), 1)
        XCTAssertEqual(AudioLevel.meterValue(dB: -30), 0.5, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.meterValue(dB: -200), 0)
        XCTAssertEqual(AudioLevel.meterValue(dB: 20), 1)
        XCTAssertEqual(AudioLevel.meterValue(dB: -10, floor: 0, ceiling: 0), 0)
    }

    func testSmootherRisesFastAndFallsSlowly() {
        var smoother = LevelSmoother(attack: 0.5, release: 0.1)
        XCTAssertEqual(smoother.process(1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(smoother.process(1), 0.75, accuracy: 0.0001)
        XCTAssertEqual(smoother.process(0), 0.675, accuracy: 0.0001)
        smoother.reset()
        XCTAssertEqual(smoother.value, 0)
    }
}
