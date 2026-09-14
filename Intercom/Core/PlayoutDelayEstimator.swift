import Foundation

/// Estimates how much playout delay the jitter buffer needs, from the measured arrival pattern.
///
/// A fixed 60 ms target is too much on a clean link and too little on a link that stalls every
/// second (AWDL channel hopping). This estimator measures, for every packet, how much later it
/// arrived than the fastest packet of the current talk spurt, and derives a target from that.
///
/// Per packet:
///
///     transit = arrivalMs − timestamp / sampleRate          (sender and receiver clocks mixed; only differences matter)
///     anchor  = min(anchor + drift, transit)                (fastest packet this spurt; the drift lets clock skew move it)
///     d       = transit − anchor                            (extra delay of this packet)
///
/// The target is the `quantile` (p95) of `d` over the last `windowPackets` packets plus one frame
/// (a frame arriving `d` late leaves a gap of a frame plus `d`), one render pull (the pull that
/// finds the buffer short asks for a whole IO buffer at once) and a safety margin, clamped to
/// `floorMs...ceilingMs`.
///
/// Growth is fast, decay is slow: a packet later than the current estimate raises it immediately
/// (a p95 alone would ignore an 80 ms stall that happens once a second), and that peak then decays
/// linearly to zero over one window (~5 s) while the p95 holds the target wherever it is higher, so
/// recurring stalls keep the target up while a link that has calmed down returns to the floor
/// within a window.
///
/// Base delay steps: the anchor only follows a *slower* path by its small drift, which would take
/// tens of seconds to absorb a lasting step (path migration, a sender whose capture paused without
/// its sample clock advancing). So when not a single packet of the last `anchorRecoveryPackets`
/// came within the anchor, the anchor moves up by the smallest delay among them: that delay is
/// evidently the new base, not jitter.
///
/// Talk spurts: the anchor is reset at the first packet of every spurt, detected as a jump in the
/// sender's sample clock that the sequence numbers do not account for (the sender's clock keeps
/// running while nothing is sent), or as an arrival gap longer than `spurtGapMs` for senders whose
/// clock pauses with transmission. Re-anchoring keeps a pause, a pre-roll burst or a sender restart
/// from being mistaken for jitter. The measurement history is kept across spurts. The default gap
/// (250 ms) sits just above what the 200 ms ceiling can absorb, so every stall the target could
/// cover is still measured, and only longer ones (which end in an underrun whatever the target) are
/// treated as a new spurt.
///
/// Pure value type; all storage is allocated in `init` and reused, so `record` never allocates.
/// Not thread-safe: the owner serializes access (the jitter buffer calls it from the push path).
struct PlayoutDelayEstimator: Equatable {
    struct Configuration: Equatable {
        /// Sample rate of the packet timestamps.
        var sampleRate: Int = Int(IntercomProtocol.sampleRate)
        /// Samples per packet.
        var frameSamples: Int = IntercomProtocol.frameSamples
        /// Lowest target ever returned.
        var floorMs: Double = 40
        /// Highest target ever returned; delays beyond this cannot be absorbed without making
        /// conversation impossible, so they are left to underrun handling.
        var ceilingMs: Double = 200
        /// Safety margin added on top of the measured delay.
        var marginMs: Double = 10
        /// Quantile of the per-packet delay distribution that the target covers.
        var quantile: Double = 0.95
        /// Number of most recent packets the quantile is computed over (~5 s at 50 packets/s).
        var windowPackets: Int = 250
        /// Upward drift of the anchor per packet, so a sender clock that runs slow cannot pin the
        /// anchor to an old minimum forever (0.02 ms per 20 ms packet tolerates 1000 ppm of skew).
        var anchorDriftMsPerPacket: Double = 0.02
        /// An arrival gap longer than this starts a new talk spurt even without a sample-clock jump.
        var spurtGapMs: Double = 250
        /// When every packet of this many consecutive packets arrived later than the anchor, the
        /// anchor is raised by the smallest of those delays (a lasting base delay step). 0 disables.
        var anchorRecoveryPackets: Int = 100

        static let `default` = Configuration()

        var frameMs: Double { Double(frameSamples) * 1000 / Double(sampleRate) }

        func normalized() -> Configuration {
            var copy = self
            copy.sampleRate = min(max(1, copy.sampleRate), 384_000)
            copy.frameSamples = min(max(1, copy.frameSamples), AudioPacket.maxSamples)
            copy.floorMs = copy.floorMs.isFinite ? min(max(0, copy.floorMs), 10_000) : 40
            copy.ceilingMs = copy.ceilingMs.isFinite ? min(max(copy.floorMs, copy.ceilingMs), 10_000) : max(copy.floorMs, 200)
            copy.marginMs = copy.marginMs.isFinite ? min(max(0, copy.marginMs), 10_000) : 0
            copy.quantile = copy.quantile.isFinite ? min(max(0.01, copy.quantile), 1) : 0.95
            copy.windowPackets = min(max(1, copy.windowPackets), 10_000)
            copy.anchorDriftMsPerPacket = copy.anchorDriftMsPerPacket.isFinite ? min(max(0, copy.anchorDriftMsPerPacket), 10) : 0
            copy.spurtGapMs = copy.spurtGapMs.isFinite ? min(max(copy.frameMs, copy.spurtGapMs), 3_600_000) : 250
            copy.anchorRecoveryPackets = min(max(0, copy.anchorRecoveryPackets), 100_000)
            return copy
        }
    }

    let configuration: Configuration

    /// Duration of one render pull in milliseconds. The jitter buffer keeps this up to date with
    /// the IO buffer size it observes; 10 ms is the preferred IO buffer duration.
    var pullQuantumMs: Double = 10

    /// Packets recorded since the last reset.
    private(set) var packetCount = 0
    /// Talk spurts (anchor resets) seen since the last reset.
    private(set) var spurtCount = 0
    /// Extra delay of the most recent packet.
    private(set) var lastDelayMs: Double = 0

    // Per-packet delays in 1 ms bins: a ring of the bins in the window plus a histogram of them,
    // so both adding a packet and reading the quantile are O(1) / O(bins) without sorting.
    private var windowBins: [UInt16]
    private var windowStart = 0
    private var windowCount = 0
    private var histogram: [Int32]

    private var anchorMs: Double?
    private var forceNewSpurt = true
    /// Height of the latest peak and how many packets ago it was set; see `peakMs`.
    private var peakHeightMs: Double = 0
    private var peakAgePackets = 0
    private var quantileMs: Double = 0
    /// Smallest delay and packet count of the current anchor-recovery block.
    private var recoveryMinimumMs: Double = .infinity
    private var recoveryCount = 0

    // Reference packet (highest sequence so far) for sample-clock unwrapping and spurt detection.
    private var referenceSequence: UInt16 = 0
    private var referenceTimestamp: UInt32 = 0
    private var referenceExtendedTimestamp: Int64 = 0
    private var lastArrivalMs: Double = 0
    private var hasReference = false

    /// Packets arriving more than this many sequence numbers behind the newest one are treated as
    /// a sender restart rather than reordering (one second of audio).
    private static let maxReorderPackets = 50

    /// Delays within this much of a bin boundary stay in the lower bin, so floating-point residue of
    /// the anchor arithmetic (a delay of 1e-12 ms) never rounds up to a whole millisecond.
    private static let binToleranceMs = 0.01

    init(configuration: Configuration = .default) {
        let normalized = configuration.normalized()
        self.configuration = normalized
        windowBins = [UInt16](repeating: 0, count: normalized.windowPackets)
        histogram = [Int32](repeating: 0, count: Self.binCount(for: normalized))
    }

    private static func binCount(for configuration: Configuration) -> Int {
        // One bin per millisecond up to the ceiling, plus an overflow bin.
        min(Int(configuration.ceilingMs.rounded(.up)), Int(UInt16.max) - 1) + 2
    }

    /// Extra delay the target covers: the quantile, or the decaying peak while it is higher.
    var delayMs: Double { max(quantileMs, peakMs) }

    /// The latest peak, falling linearly to exactly zero over one window. Computed from an integer
    /// age rather than by repeated subtraction, so it reaches zero without floating-point residue.
    private var peakMs: Double {
        let window = windowBins.count
        guard peakAgePackets < window else { return 0 }
        return peakHeightMs * Double(window - peakAgePackets) / Double(window)
    }

    /// Quantile of the per-packet delay over the window, without the peak.
    var quantileDelayMs: Double { quantileMs }

    /// Recommended playout delay: delay + one frame + one pull + margin, clamped to floor...ceiling.
    var targetMs: Double {
        let raw = delayMs + configuration.frameMs + max(0, pullQuantumMs) + configuration.marginMs
        return min(max(raw, configuration.floorMs), configuration.ceilingMs)
    }

    /// Makes the next packet start a new talk spurt (re-anchor), e.g. after the stream restarted.
    mutating func beginTalkSpurt() {
        forceNewSpurt = true
    }

    /// Forgets all history and returns to the floor. Keeps `pullQuantumMs` and never allocates.
    mutating func reset() {
        for index in windowBins.indices { windowBins[index] = 0 }
        for index in histogram.indices { histogram[index] = 0 }
        windowStart = 0
        windowCount = 0
        packetCount = 0
        spurtCount = 0
        lastDelayMs = 0
        anchorMs = nil
        forceNewSpurt = true
        peakHeightMs = 0
        peakAgePackets = 0
        quantileMs = 0
        recoveryMinimumMs = .infinity
        recoveryCount = 0
        referenceSequence = 0
        referenceTimestamp = 0
        referenceExtendedTimestamp = 0
        lastArrivalMs = 0
        hasReference = false
    }

    /// Records one received packet and returns its extra delay `d` in milliseconds (≥ 0).
    @discardableResult
    mutating func record(sequence: UInt16, timestamp: UInt32, arrival: MonotonicTime) -> Double {
        let arrivalMs = Double(arrival.nanoseconds) / 1_000_000
        let frame = Int64(configuration.frameSamples)

        var startsSpurt = forceNewSpurt || !hasReference
        let extendedTimestamp: Int64
        if hasReference {
            let timestampDelta = Int64(Int32(bitPattern: timestamp &- referenceTimestamp))
            extendedTimestamp = referenceExtendedTimestamp + timestampDelta
            let sequenceDelta = SequenceNumber.distance(from: referenceSequence, to: sequence)
            if sequenceDelta > 0 {
                // A newer packet. Its sample clock may advance by exactly the frames in between
                // (lost packets); anything more means the sender paused, anything less that it restarted.
                let expected = Int64(sequenceDelta) * frame
                if timestampDelta > expected + frame / 2 || timestampDelta < 0 {
                    startsSpurt = true
                }
                if arrivalMs - lastArrivalMs > configuration.spurtGapMs {
                    startsSpurt = true
                }
                referenceSequence = sequence
                referenceTimestamp = timestamp
                referenceExtendedTimestamp = extendedTimestamp
                lastArrivalMs = arrivalMs
            } else if sequenceDelta < -Self.maxReorderPackets {
                // Far older than anything a reordering network produces: the sender restarted
                // its sequence numbers. Take this packet as the new reference.
                startsSpurt = true
                referenceSequence = sequence
                referenceTimestamp = timestamp
                referenceExtendedTimestamp = extendedTimestamp
                lastArrivalMs = arrivalMs
            }
        } else {
            extendedTimestamp = 0
            referenceSequence = sequence
            referenceTimestamp = timestamp
            referenceExtendedTimestamp = 0
            lastArrivalMs = arrivalMs
            hasReference = true
        }

        let transitMs = arrivalMs - Double(extendedTimestamp) * 1000 / Double(configuration.sampleRate)
        let delay: Double
        if !startsSpurt, let anchor = anchorMs {
            let newAnchor = min(anchor + configuration.anchorDriftMsPerPacket, transitMs)
            anchorMs = newAnchor
            delay = max(0, transitMs - newAnchor)
            recoverAnchorIfStepped(delay: delay)
        } else {
            anchorMs = transitMs
            forceNewSpurt = false
            spurtCount += 1
            delay = 0
            recoveryMinimumMs = .infinity
            recoveryCount = 0
        }

        insert(delayMs: delay)
        packetCount += 1
        lastDelayMs = delay
        return delay
    }

    // MARK: - Private

    /// Raises the anchor after a whole block of packets that all arrived later than it.
    private mutating func recoverAnchorIfStepped(delay: Double) {
        let blockSize = configuration.anchorRecoveryPackets
        guard blockSize > 0, let anchor = anchorMs else { return }
        recoveryMinimumMs = min(recoveryMinimumMs, delay)
        recoveryCount += 1
        guard recoveryCount >= blockSize else { return }
        if recoveryMinimumMs > Self.binToleranceMs {
            anchorMs = anchor + recoveryMinimumMs
        }
        recoveryMinimumMs = .infinity
        recoveryCount = 0
    }

    private mutating func insert(delayMs delay: Double) {
        let lastBin = histogram.count - 1
        let bin = delay >= Double(lastBin) ? lastBin : max(0, Int((delay - Self.binToleranceMs).rounded(.up)))
        if windowCount == windowBins.count {
            let evicted = Int(windowBins[windowStart])
            histogram[evicted] -= 1
            windowBins[windowStart] = UInt16(bin)
            windowStart = (windowStart + 1) % windowBins.count
        } else {
            windowBins[(windowStart + windowCount) % windowBins.count] = UInt16(bin)
            windowCount += 1
        }
        histogram[bin] += 1

        // Smallest bin whose cumulative count reaches the quantile rank.
        let rank = max(1, Int((configuration.quantile * Double(windowCount)).rounded(.up)))
        var cumulative = 0
        var quantileBin = lastBin
        for index in histogram.indices {
            cumulative += Int(histogram[index])
            if cumulative >= rank {
                quantileBin = index
                break
            }
        }
        quantileMs = Double(quantileBin)

        // The peak falls linearly to zero over one window; the quantile takes over wherever it is higher.
        let measured = Double(bin)
        if measured > delayMs {
            peakHeightMs = measured
            peakAgePackets = 0
        } else if peakAgePackets < windowBins.count {
            peakAgePackets += 1
        }
    }
}
