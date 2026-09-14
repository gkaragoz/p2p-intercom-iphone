import Foundation
import os
import UIKit

/// Short `beginBackgroundTask` windows around discrete recovery work: handling an audio interruption
/// (tell the peer, post a notification), an engine rebuild, a transport replacement.
///
/// It is NOT what keeps the intercom alive in the background; running audio I/O does that. A window
/// only makes sure a job that starts while audio is down (so the app is about to be suspended) gets
/// to finish. Every window is ended exactly once: by `end`, by its own time limit, or by the system's
/// expiration handler, whichever comes first (a task that is never ended gets the app killed).
///
/// Thread-safe: `beginBackgroundTask` and `endBackgroundTask` are documented as safe to call from any
/// thread, and the engine's recovery attempts run on the audio engine queue. They also do not wait for
/// the main thread (checked on the iOS 26 simulator with main blocked), which matters because main can
/// be blocked in `engineQueue.sync` (engine stop) while an attempt holds the engine queue.
final class BackgroundActivity: @unchecked Sendable {
    static let shared = BackgroundActivity()

    private final class Window {
        let name: String
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var isFinished = false
        /// Bumped whenever the time limit is rescheduled; older limits then do nothing.
        var generation = 0

        init(name: String) {
            self.name = name
        }
    }

    private let lock = NSLock()
    private var named: [String: Window] = [:]
    private static let log = Logger(subsystem: "intercom", category: "background")

    /// Begins the named window, or moves the time limit of the one already open (no second task).
    func begin(_ name: String, maxDuration: TimeInterval) {
        lock.lock()
        if let window = named[name] {
            window.generation += 1
            let generation = window.generation
            lock.unlock()
            scheduleLimit(window, generation: generation, after: maxDuration)
            return
        }
        let window = Window(name: name)
        named[name] = window
        lock.unlock()

        guard start(window) else { return }
        lock.lock()
        let generation = window.generation
        lock.unlock()
        scheduleLimit(window, generation: generation, after: maxDuration)
    }

    /// Ends the named window now, or after `delay` (e.g. to let a just-sent status datagram leave).
    func end(_ name: String, after delay: TimeInterval = 0) {
        lock.lock()
        guard let window = named[name] else {
            lock.unlock()
            return
        }
        guard delay > 0 else {
            lock.unlock()
            finish(window, reason: "done")
            return
        }
        window.generation += 1
        let generation = window.generation
        lock.unlock()
        scheduleLimit(window, generation: generation, after: delay, reason: "done")
    }

    /// Runs `body` inside its own window (not shared with other callers of the same name).
    func perform<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let window = Window(name: name)
        let started = start(window)
        defer {
            if started { finish(window, reason: "done") }
        }
        return try body()
    }

    // MARK: - Private

    /// Returns false when no task could be started (the window is then already finished).
    private func start(_ window: Window) -> Bool {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: window.name) { [weak self] in
            // Main thread, must return quickly.
            self?.finish(window, reason: "expired")
        }
        lock.lock()
        guard identifier != .invalid else {
            window.isFinished = true
            if named[window.name] === window {
                named[window.name] = nil
            }
            lock.unlock()
            Self.log.error("background task \(window.name, privacy: .public) could not be started")
            return false
        }
        if window.isFinished {
            // Ended (or expired) before `beginBackgroundTask` even returned.
            lock.unlock()
            UIApplication.shared.endBackgroundTask(identifier)
            return false
        }
        window.identifier = identifier
        lock.unlock()
        Self.log.notice("background task \(window.name, privacy: .public) began")
        return true
    }

    private func finish(_ window: Window, reason: String) {
        lock.lock()
        guard !window.isFinished else {
            lock.unlock()
            return
        }
        window.isFinished = true
        if named[window.name] === window {
            named[window.name] = nil
        }
        let identifier = window.identifier
        window.identifier = .invalid
        lock.unlock()
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        Self.log.notice("background task \(window.name, privacy: .public) ended (\(reason, privacy: .public))")
    }

    private func scheduleLimit(_ window: Window, generation: Int, after delay: TimeInterval, reason: String = "time limit") {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = window.generation == generation && !window.isFinished
            self.lock.unlock()
            if current {
                self.finish(window, reason: reason)
            }
        }
    }
}
