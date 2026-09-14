import Foundation
import XCTest
@testable import IntercomCore

final class UpdateThrottleTests: XCTestCase {
    /// A stand-in for the Live Activity state: `link` changes are essential, `detail` is cosmetic.
    private struct Mirror: Equatable {
        var link: Int
        var detail: Int
    }

    private func makeThrottle(refresh: TimeInterval? = 600) -> UpdateThrottle<Mirror> {
        UpdateThrottle(configuration: .init(essentialInterval: 1, cosmeticInterval: 5, refreshInterval: refresh)) {
            $0.link != $1.link
        }
    }

    func testNothingIsDueWithoutAState() {
        var throttle = makeThrottle()
        XCTAssertNil(throttle.nextDeadline)
        XCTAssertNil(throttle.takeDue(now: MonotonicTime(seconds: 10)))
        XCTAssertNil(throttle.takeImmediately(now: MonotonicTime(seconds: 10)))
    }

    func testFirstStateIsPublishedAtOnce() {
        var throttle = makeThrottle()
        let now = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertLessThanOrEqual(throttle.nextDeadline!, now)
        XCTAssertEqual(throttle.takeDue(now: now), Mirror(link: 1, detail: 0))
        XCTAssertEqual(throttle.published, Mirror(link: 1, detail: 0))
    }

    func testEssentialChangesAreCoalescedToOnePerSecond() {
        var throttle = makeThrottle()
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))

        throttle.submit(Mirror(link: 2, detail: 0))
        throttle.submit(Mirror(link: 3, detail: 0))
        XCTAssertEqual(throttle.nextDeadline, start + 1)
        XCTAssertNil(throttle.takeDue(now: start + 0.5), "not before the essential interval")
        XCTAssertEqual(throttle.takeDue(now: start + 1), Mirror(link: 3, detail: 0), "the latest state wins")
        XCTAssertNil(throttle.takeDue(now: start + 1.1), "nothing new")
    }

    func testCosmeticChangesWaitFiveSecondsSinceTheLastPublish() {
        var throttle = makeThrottle()
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))

        throttle.submit(Mirror(link: 1, detail: 1))
        XCTAssertEqual(throttle.nextDeadline, start + 5)
        XCTAssertNil(throttle.takeDue(now: start + 4.9))
        XCTAssertEqual(throttle.takeDue(now: start + 5), Mirror(link: 1, detail: 1))
    }

    func testEssentialChangeCarriesPendingCosmeticChangeEarly() {
        var throttle = makeThrottle()
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))

        throttle.submit(Mirror(link: 1, detail: 7))
        XCTAssertEqual(throttle.nextDeadline, start + 5)
        throttle.submit(Mirror(link: 2, detail: 7))
        XCTAssertEqual(throttle.nextDeadline, start + 1, "an essential change pulls the deadline in")
        XCTAssertEqual(throttle.takeDue(now: start + 2), Mirror(link: 2, detail: 7))
    }

    func testRevertingToThePublishedStateCancelsTheUpdate() {
        var throttle = makeThrottle(refresh: nil)
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))

        throttle.submit(Mirror(link: 1, detail: 3))
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNil(throttle.nextDeadline)
        XCTAssertNil(throttle.takeDue(now: start + 10))
    }

    func testUnchangedStateIsRepublishedEveryRefreshInterval() {
        var throttle = makeThrottle(refresh: 600)
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))
        XCTAssertEqual(throttle.nextDeadline, start + 600)
        XCTAssertNil(throttle.takeDue(now: start + 599))
        XCTAssertEqual(throttle.takeDue(now: start + 600), Mirror(link: 1, detail: 0))
        XCTAssertEqual(throttle.nextDeadline, start + 1200)
    }

    func testImmediatePublishIgnoresIntervalsButNotDuplicates() {
        var throttle = makeThrottle()
        let start = MonotonicTime(seconds: 10)
        throttle.submit(Mirror(link: 1, detail: 0))
        XCTAssertNotNil(throttle.takeDue(now: start))

        XCTAssertNil(throttle.takeImmediately(now: start + 0.1), "same state: nothing to send")
        throttle.submit(Mirror(link: 1, detail: 4))
        XCTAssertEqual(throttle.takeImmediately(now: start + 0.2), Mirror(link: 1, detail: 4))
        XCTAssertEqual(throttle.publishedAt, start + 0.2)
        throttle.submit(Mirror(link: 2, detail: 4))
        XCTAssertEqual(throttle.nextDeadline, start + 1.2, "intervals count from the forced publish")
    }

    func testMarkPublishedAndReset() {
        var throttle = makeThrottle()
        let start = MonotonicTime(seconds: 10)
        throttle.markPublished(Mirror(link: 5, detail: 5), now: start)
        XCTAssertEqual(throttle.latest, Mirror(link: 5, detail: 5))
        XCTAssertNil(throttle.takeDue(now: start + 1))

        throttle.reset()
        XCTAssertNil(throttle.published)
        throttle.submit(Mirror(link: 5, detail: 5))
        XCTAssertEqual(throttle.takeDue(now: start + 1), Mirror(link: 5, detail: 5), "after a reset the state is new again")
    }
}

final class BooleanHysteresisTests: XCTestCase {
    func testTurnsOnOnlyAfterTheInputHeldForTheOnDelay() {
        var filter = BooleanHysteresis(onDelay: 0.3, offDelay: 1.5)
        let start = MonotonicTime(seconds: 10)
        XCTAssertFalse(filter.update(true, now: start))
        XCTAssertEqual(filter.pendingDeadline, start + 0.3)
        XCTAssertFalse(filter.update(true, now: start + 0.2))
        XCTAssertTrue(filter.update(true, now: start + 0.3))
        XCTAssertNil(filter.pendingDeadline)
    }

    func testShortBlipIsIgnored() {
        var filter = BooleanHysteresis(onDelay: 0.3, offDelay: 1.5)
        let start = MonotonicTime(seconds: 10)
        filter.update(true, now: start)
        XCTAssertFalse(filter.update(false, now: start + 0.1))
        XCTAssertNil(filter.pendingDeadline)
        XCTAssertFalse(filter.update(true, now: start + 0.35), "the hold restarts after a blip")
        XCTAssertEqual(filter.pendingDeadline, start + 0.65)
    }

    func testTurnsOffOnlyAfterTheOffDelay() {
        var filter = BooleanHysteresis(onDelay: 0, offDelay: 1.5)
        let start = MonotonicTime(seconds: 10)
        XCTAssertTrue(filter.update(true, now: start), "a zero on-delay follows at once")
        XCTAssertTrue(filter.update(false, now: start + 1))
        XCTAssertEqual(filter.pendingDeadline, start + 2.5)
        XCTAssertTrue(filter.update(true, now: start + 2), "talking again before the delay keeps it on")
        XCTAssertTrue(filter.update(false, now: start + 3))
        XCTAssertTrue(filter.update(false, now: start + 4.4))
        XCTAssertFalse(filter.update(false, now: start + 4.5))
    }

    func testReset() {
        var filter = BooleanHysteresis(onDelay: 0.3, offDelay: 1.5, initialValue: true)
        let start = MonotonicTime(seconds: 10)
        filter.update(false, now: start)
        XCTAssertNotNil(filter.pendingDeadline)
        filter.reset()
        XCTAssertFalse(filter.value)
        XCTAssertNil(filter.pendingDeadline)
    }
}
