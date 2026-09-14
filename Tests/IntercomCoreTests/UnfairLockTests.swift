import Foundation
import XCTest
@testable import IntercomCore

final class UnfairLockTests: XCTestCase {
    func testTryLockFailsWhileAnotherThreadHoldsTheLock() {
        let lock = UnfairLock()
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lock.lock()
            holding.signal()
            release.wait()
            lock.unlock()
            finished.signal()
        }
        holding.wait()
        XCTAssertFalse(lock.tryLock())
        XCTAssertFalse(lock.tryLock(spinning: 1_000), "spinning is bounded and never waits for the owner")
        release.signal()
        finished.wait()
        XCTAssertTrue(lock.tryLock())
        lock.unlock()
        XCTAssertTrue(lock.tryLock(spinning: 0), "at least one attempt")
        lock.unlock()
    }

    func testWithLockProvidesMutualExclusion() {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let lock = UnfairLock()
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10_000 {
                lock.withLock { counter.value += 1 }
            }
        }
        XCTAssertEqual(lock.withLock { counter.value }, 80_000)
    }
}
