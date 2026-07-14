import XCTest
@testable import RebornQuotaCore

final class LocatorPollCoordinatorTests: XCTestCase {
    func testNotificationBurstSchedulesOneImmediatePollAndOneFollowUpAtMost() {
        var coordinator = LocatorPollCoordinator()
        coordinator.start()

        XCTAssertTrue(coordinator.receiveInvalidation())
        XCTAssertFalse(coordinator.receiveInvalidation())
        XCTAssertFalse(coordinator.beginTimerPoll(), "Queued immediate validation wins over timer")
        XCTAssertTrue(coordinator.beginImmediatePoll())
        XCTAssertFalse(coordinator.receiveInvalidation())
        XCTAssertFalse(coordinator.receiveInvalidation())
        XCTAssertTrue(coordinator.finishPoll(), "Burst during a poll requests one follow-up")
        XCTAssertFalse(coordinator.finishPoll())
        XCTAssertTrue(coordinator.beginImmediatePoll())
        XCTAssertFalse(coordinator.finishPoll())
    }

    func testTimerCannotOverlapPollAndStopClearsPendingWork() {
        var coordinator = LocatorPollCoordinator()
        coordinator.start()
        XCTAssertTrue(coordinator.beginTimerPoll())
        XCTAssertFalse(coordinator.beginTimerPoll())
        XCTAssertTrue(coordinator.finishPoll())

        coordinator.stop()
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertFalse(coordinator.beginImmediatePoll())
        XCTAssertFalse(coordinator.beginTimerPoll())
        XCTAssertFalse(coordinator.receiveInvalidation())
    }

    func testCadenceKeepsAdaptiveVerificationWhenAXMoveNotificationsAreMissed() {
        var cadence = LocatorPollingCadence()
        XCTAssertEqual(
            cadence.interval(notificationsActive: true, boundsChanged: true, now: 10),
            1.0 / 60.0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            cadence.interval(notificationsActive: true, boundsChanged: false, now: 10.299),
            1.0 / 60.0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            cadence.interval(notificationsActive: true, boundsChanged: false, now: 10.300),
            0.100,
            accuracy: 0.000_1
        )

        XCTAssertEqual(
            cadence.interval(notificationsActive: false, boundsChanged: true, now: 20),
            1.0 / 60.0,
            accuracy: 0.000_1
        )
        cadence.reset()
        XCTAssertEqual(
            cadence.interval(notificationsActive: false, boundsChanged: false, now: 99),
            0.100,
            accuracy: 0.000_1
        )
    }
}
