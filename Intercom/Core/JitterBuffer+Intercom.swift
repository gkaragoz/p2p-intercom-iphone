import Foundation

extension JitterBuffer.Configuration {
    /// The intercom's jitter buffer settings for a playout target, a wire rate and a latency profile.
    ///
    /// `(.standard, .balanced)` reproduces the pre-preset configuration exactly. The wire rate sets
    /// the frame size and sample rate (the fixed target stays a count of 20 ms frames, so `targetMs`
    /// means the same at every rate) and scales the crossfade so it keeps its 2.5 ms. The profile
    /// only bounds the adaptive estimator; its frame size and rate follow the buffer's through
    /// `normalized()`, which also raises the cap far enough to hold the profile's ceiling.
    ///
    /// - Parameters:
    ///   - targetMs: fixed playout delay, used when `adaptive` is off.
    ///   - adaptive: follow `PlayoutDelayEstimator` between the profile's floor and ceiling.
    static func intercom(targetMs: Double, adaptive: Bool, wireRate: WireRate = .standard,
                         profile: LatencyProfile = .balanced) -> JitterBuffer.Configuration {
        var configuration = JitterBuffer.Configuration.default
        let frames = Int((targetMs / (IntercomProtocol.frameDuration * 1000)).rounded())
        configuration.targetDelayFrames = max(1, frames)
        configuration.adaptiveTarget = adaptive
        configuration.maxDelayFrames = max(configuration.targetDelayFrames + 4, 12)
        configuration.frameSize = wireRate.frameSamples
        configuration.sampleRate = wireRate.sampleRate
        // 40 samples is 2.5 ms at 16 kHz; keep the duration, not the sample count.
        configuration.crossfadeSamples = 40 * wireRate.sampleRate / 16_000
        configuration.playoutDelay.floorMs = profile.playoutFloorMs
        configuration.playoutDelay.ceilingMs = profile.playoutCeilingMs
        configuration.playoutDelay.marginMs = profile.playoutMarginMs
        return configuration.normalized()
    }
}
