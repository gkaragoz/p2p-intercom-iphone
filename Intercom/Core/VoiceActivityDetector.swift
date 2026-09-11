import Foundation

/// Level-threshold voice activity detector with hangover, used by the voice-activated transmit mode.
///
/// One `process` call per 20 ms frame. Activity begins as soon as a frame is at or above the
/// threshold and lasts for `hangoverFrames` additional frames after the last loud frame, so the
/// tail of a word is not clipped.
struct VoiceActivityDetector: Equatable {
    var thresholdDB: Float
    var hangoverFrames: Int
    private(set) var isActive = false
    private var remainingHangover = 0

    init(thresholdDB: Float = -38, hangoverFrames: Int = 25) {
        self.thresholdDB = thresholdDB
        self.hangoverFrames = max(0, hangoverFrames)
    }

    @discardableResult
    mutating func process(levelDB: Float) -> Bool {
        if levelDB >= thresholdDB {
            isActive = true
            remainingHangover = hangoverFrames
        } else if remainingHangover > 0 {
            remainingHangover -= 1
            isActive = true
        } else {
            isActive = false
        }
        return isActive
    }

    mutating func reset() {
        isActive = false
        remainingHangover = 0
    }
}
