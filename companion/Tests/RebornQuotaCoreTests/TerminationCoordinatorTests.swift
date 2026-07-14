import XCTest
@testable import RebornQuotaCore

final class TerminationCoordinatorTests: XCTestCase {
    func testFirstSignalBeginsOneBoundedShutdownAndDuplicatesAreIgnored() {
        var coordinator = TerminationCoordinatorState()

        XCTAssertEqual(coordinator.receiveSignal(), [
            .beginLifecycleShutdown,
            .scheduleForcedCompletion(after: 4),
        ])
        XCTAssertEqual(coordinator.receiveSignal(), [])
        XCTAssertEqual(coordinator.phase, .shuttingDown)
    }

    func testFinishedReapMarksCleanAndExitsSuccessfully() {
        var coordinator = TerminationCoordinatorState()
        _ = coordinator.receiveSignal()

        XCTAssertEqual(coordinator.shutdownFinished(), [
            .markCleanExit,
            .exitSuccessfully,
        ])
        XCTAssertEqual(coordinator.shutdownTimedOut(), [])
        XCTAssertEqual(coordinator.phase, .finished)
    }

    func testDelayedReaperFinishesBeforeDeadlineWithoutForcedExit() {
        var coordinator = TerminationCoordinatorState()
        _ = coordinator.receiveSignal()

        XCTAssertEqual(coordinator.shutdownFinished(), [
            .markCleanExit,
            .exitSuccessfully,
        ])
        XCTAssertEqual(coordinator.shutdownTimedOut(), [])
    }

    func testForcedTimeoutDoesNotFalselyMarkCleanAndExitsAsFailure() {
        var coordinator = TerminationCoordinatorState()
        _ = coordinator.receiveSignal()

        XCTAssertEqual(coordinator.shutdownTimedOut(), [.exitFailure])
        XCTAssertEqual(coordinator.shutdownFinished(), [])
    }
}
