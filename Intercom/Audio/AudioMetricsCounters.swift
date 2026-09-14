import Darwin
import Foundation
import Synchronization

/// Lock-free latency counters for the audio path.
///
/// Writers are the real-time capture (sink node) or tap callback, the real-time render callback and
/// the capture worker; the reader is the audio engine's one-second sampler. Every field is an
/// `Atomic`, so writers never take a lock, allocate or make a system call:
/// * cumulative counters only grow (`add`),
/// * window extremes are raised or lowered with a compare-and-exchange loop, and the reader resets
///   them with `exchange` as it reads, so an update racing with a read lands in one window or the
///   next but is never lost or duplicated.
final class AudioMetricsCounters: @unchecked Sendable {
    let captureCallbacks = Atomic<Int>(0)
    let captureFrames = Atomic<Int>(0)
    let captureOverrunSamples = Atomic<Int>(0)
    let captureFramesMin = Atomic<Int>(Int.max)
    let captureFramesMax = Atomic<Int>(0)
    /// Host-time ticks (`mach_absolute_time` units).
    let captureMaxIntervalTicks = Atomic<UInt64>(0)

    let deliveredFrames = Atomic<Int>(0)
    let deliveryLagSumNs = Atomic<Int>(0)
    let deliveryLagCount = Atomic<Int>(0)
    let deliveryLagMaxNs = Atomic<Int>(0)

    let renderCallbacks = Atomic<Int>(0)
    let renderEarlyReturns = Atomic<Int>(0)
    let renderFramesMin = Atomic<Int>(Int.max)
    let renderFramesMax = Atomic<Int>(0)
    let renderMaxIntervalTicks = Atomic<UInt64>(0)

    /// Reads every counter and starts a new window for the extremes.
    func read() -> AudioCounterReading {
        var reading = AudioCounterReading()
        reading.captureCallbacks = captureCallbacks.load(ordering: .relaxed)
        reading.captureFrames = captureFrames.load(ordering: .relaxed)
        reading.captureOverrunSamples = captureOverrunSamples.load(ordering: .relaxed)
        reading.deliveredFrames = deliveredFrames.load(ordering: .relaxed)
        reading.deliveryLagSumNs = deliveryLagSumNs.load(ordering: .relaxed)
        reading.deliveryLagCount = deliveryLagCount.load(ordering: .relaxed)
        reading.renderCallbacks = renderCallbacks.load(ordering: .relaxed)
        reading.renderEarlyReturns = renderEarlyReturns.load(ordering: .relaxed)

        let captureMin = captureFramesMin.exchange(Int.max, ordering: .relaxed)
        reading.windowCaptureFramesMin = captureMin == Int.max ? nil : captureMin
        let captureMax = captureFramesMax.exchange(0, ordering: .relaxed)
        reading.windowCaptureFramesMax = captureMax == 0 ? nil : captureMax
        let captureInterval = captureMaxIntervalTicks.exchange(0, ordering: .relaxed)
        reading.windowCaptureMaxIntervalNs = captureInterval == 0 ? nil : HostTime.nanoseconds(fromTicks: captureInterval)
        let lagMax = deliveryLagMaxNs.exchange(0, ordering: .relaxed)
        reading.windowDeliveryLagMaxNs = lagMax == 0 ? nil : lagMax
        let renderMin = renderFramesMin.exchange(Int.max, ordering: .relaxed)
        reading.windowRenderFramesMin = renderMin == Int.max ? nil : renderMin
        let renderMax = renderFramesMax.exchange(0, ordering: .relaxed)
        reading.windowRenderFramesMax = renderMax == 0 ? nil : renderMax
        let renderInterval = renderMaxIntervalTicks.exchange(0, ordering: .relaxed)
        reading.windowRenderMaxIntervalNs = renderInterval == 0 ? nil : HostTime.nanoseconds(fromTicks: renderInterval)
        return reading
    }
}

/// Raises `atomic` to `value` if it is lower. Lock-free; real-time safe.
@inline(__always)
func atomicRaise(_ atomic: borrowing Atomic<Int>, to value: Int) {
    var current = atomic.load(ordering: .relaxed)
    while value > current {
        let result = atomic.compareExchange(expected: current, desired: value, ordering: .relaxed)
        if result.exchanged { return }
        current = result.original
    }
}

/// Raises `atomic` to `value` if it is lower. Lock-free; real-time safe.
@inline(__always)
func atomicRaise(_ atomic: borrowing Atomic<UInt64>, to value: UInt64) {
    var current = atomic.load(ordering: .relaxed)
    while value > current {
        let result = atomic.compareExchange(expected: current, desired: value, ordering: .relaxed)
        if result.exchanged { return }
        current = result.original
    }
}

/// Lowers `atomic` to `value` if it is higher. Lock-free; real-time safe.
@inline(__always)
func atomicLower(_ atomic: borrowing Atomic<Int>, to value: Int) {
    var current = atomic.load(ordering: .relaxed)
    while value < current {
        let result = atomic.compareExchange(expected: current, desired: value, ordering: .relaxed)
        if result.exchanged { return }
        current = result.original
    }
}

/// `mach_absolute_time` helpers. Core Audio time stamps (`AudioTimeStamp.mHostTime`, `AVAudioTime.hostTime`)
/// use the same clock, so capture times and "now" can be compared directly.
enum HostTime {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(1, info.numer)), UInt64(max(1, info.denom)))
    }()

    @inline(__always)
    static func now() -> UInt64 {
        mach_absolute_time()
    }

    static func nanoseconds(fromTicks ticks: UInt64) -> Int {
        let (high, low) = ticks.multipliedFullWidth(by: timebase.numer)
        guard high < timebase.denom else { return Int.max }
        let nanoseconds = timebase.denom.dividingFullWidth((high, low)).quotient
        return Int(clamping: nanoseconds)
    }

    /// Host-time ticks covering `seconds`.
    static func ticks(fromSeconds seconds: Double) -> Double {
        seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }
}
