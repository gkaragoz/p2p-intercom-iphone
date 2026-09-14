import Foundation
#if canImport(os)
import os
#endif

/// A small mutual-exclusion lock whose `tryLock()` is safe to call from a real-time audio thread.
///
/// The render callback must never block: a blocked render thread is an audible dropout, and waiting
/// on a lock held by a lower-priority thread is a priority inversion. The audio path therefore only
/// ever calls `tryLock()` (which returns immediately) and treats contention as "no audio this
/// cycle". Non-real-time threads use `lock()`.
///
/// On Apple platforms this wraps `os_unfair_lock`, which donates priority to the owner when a
/// thread does wait and whose `trylock` is a single compare-and-swap without system calls. The
/// lock storage is allocated once with a stable address, as `os_unfair_lock` requires (a Swift
/// stored property of struct type may move). Linux has no unfair lock in Foundation, so the unit
/// tests there use `NSLock`, whose `try()` is non-blocking as well.
///
/// The lock is not recursive, and it must be unlocked by the thread that locked it.
final class UnfairLock: @unchecked Sendable {
    #if canImport(os)
    private let storage: UnsafeMutablePointer<os_unfair_lock_s>
    #else
    private let storage = NSLock()
    #endif

    init() {
        #if canImport(os)
        storage = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock_s())
        #endif
    }

    deinit {
        #if canImport(os)
        storage.deinitialize(count: 1)
        storage.deallocate()
        #endif
    }

    /// Blocks until the lock is acquired. Never call this on a real-time thread.
    func lock() {
        #if canImport(os)
        os_unfair_lock_lock(storage)
        #else
        storage.lock()
        #endif
    }

    func unlock() {
        #if canImport(os)
        os_unfair_lock_unlock(storage)
        #else
        storage.unlock()
        #endif
    }

    /// Acquires the lock only if nobody holds it; never waits. Real-time safe.
    func tryLock() -> Bool {
        #if canImport(os)
        return os_unfair_lock_trylock(storage)
        #else
        return storage.try()
        #endif
    }

    /// Retries `tryLock()` up to `attempts` times without yielding or sleeping.
    ///
    /// The critical sections behind the audio locks are a handful of instructions long, so on a
    /// multi-core device a render callback that collides with one almost always gets the lock a
    /// few spins later. The spin is bounded, so the worst case is still a fixed, tiny delay.
    func tryLock(spinning attempts: Int) -> Bool {
        var remaining = max(1, attempts)
        while remaining > 0 {
            if tryLock() { return true }
            remaining -= 1
        }
        return false
    }

    @inline(__always)
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
