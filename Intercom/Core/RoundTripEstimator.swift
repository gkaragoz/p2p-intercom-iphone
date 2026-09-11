import Foundation

/// Tracks outstanding pings and produces a smoothed round-trip time.
struct RoundTripEstimator: Equatable {
    private var outstanding: [UInt32: UInt64] = [:]
    private var nextID: UInt32 = 1
    private(set) var lastRTTMs: Double?
    private(set) var smoothedRTTMs: Double?

    /// Pings never answered are forgotten once this many newer ones are in flight.
    var maxOutstanding = 8
    /// Weight of the newest sample in the exponential moving average.
    var smoothing = 0.3

    init() {}

    mutating func makePing(nowMs: UInt64) -> ControlMessage.Ping {
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        outstanding[id] = nowMs
        while outstanding.count > maxOutstanding, let oldest = outstanding.min(by: { $0.value < $1.value }) {
            outstanding.removeValue(forKey: oldest.key)
        }
        return ControlMessage.Ping(id: id, sentAtMs: nowMs)
    }

    /// Returns the measured round-trip time in milliseconds, or `nil` for an unknown/stale pong.
    @discardableResult
    mutating func receivePong(_ pong: ControlMessage.Ping, nowMs: UInt64) -> Double? {
        guard let sentAt = outstanding.removeValue(forKey: pong.id) else { return nil }
        let rtt = nowMs >= sentAt ? Double(nowMs - sentAt) : 0
        lastRTTMs = rtt
        if let previous = smoothedRTTMs {
            smoothedRTTMs = previous + (rtt - previous) * smoothing
        } else {
            smoothedRTTMs = rtt
        }
        return rtt
    }

    mutating func reset() {
        outstanding.removeAll()
        lastRTTMs = nil
        smoothedRTTMs = nil
    }
}
