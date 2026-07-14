import XCTest
@testable import RebornQuotaCore

final class AppLifecycleStateTests: XCTestCase {
    func testHostAbsentDoesNotStartRuntime() {
        var machine = AppLifecycleState()

        XCTAssertEqual(machine.bootstrap(hostIsRunning: false), [.installHostMonitors])
        XCTAssertEqual(machine.phase, .waitingForHost)
        XCTAssertFalse(machine.appServerIsRunning)
    }

    func testHostPresentStartsAppServerAndLocatorOnce() {
        var machine = AppLifecycleState()

        XCTAssertEqual(machine.bootstrap(hostIsRunning: true), [
            .installHostMonitors,
            .startAppServer,
            .startPetLocator,
        ])
        XCTAssertEqual(machine.hostLaunched(), [])
        XCTAssertEqual(machine.phase, .hostRunning)
        XCTAssertTrue(machine.appServerIsRunning)
    }

    func testHostExitCancelsChildStopsLocatorAndHidesPanel() {
        var machine = AppLifecycleState()
        _ = machine.bootstrap(hostIsRunning: true)

        XCTAssertEqual(machine.hostTerminated(), [
            .stopAppServerAndReapChild,
            .stopPetLocator,
            .hidePanel,
        ])
        XCTAssertEqual(machine.phase, .waitingForHost)
        XCTAssertFalse(machine.appServerIsRunning)
    }

    func testShutdownCleansEveryMonitorAndRuntimeResource() {
        var machine = AppLifecycleState()
        _ = machine.bootstrap(hostIsRunning: true)

        XCTAssertEqual(machine.shutdown(), [
            .stopAppServerAndReapChild,
            .stopPetLocator,
            .hidePanel,
            .removeHostMonitors,
        ])
        XCTAssertEqual(machine.shutdown(), [])
        XCTAssertEqual(machine.phase, .stopped)
    }

    func testSingleInstanceRejectionExitsSuccessfully() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(lockAcquired: false),
            .exitSuccessfully
        )
        XCTAssertEqual(
            SingleInstancePolicy.decision(lockAcquired: true),
            .continueLaunching
        )
    }

    func testRapidHostRelaunchWaitsForOldGenerationReapBeforeStartingNewOne() {
        var coordinator = AppServerLifecycleCoordinator()
        XCTAssertEqual(
            coordinator.requestStart(hostPresent: true, permissionReady: true, blocked: false),
            [.start(generation: 1)]
        )
        XCTAssertEqual(coordinator.requestStop(), [.cancelAndReap(generation: 1)])
        XCTAssertEqual(
            coordinator.requestStart(hostPresent: true, permissionReady: true, blocked: false),
            []
        )
        XCTAssertEqual(
            coordinator.reapCompleted(
                generation: 1,
                hostPresent: true,
                permissionReady: true,
                blocked: false
            ),
            [.start(generation: 2)]
        )
    }

    func testStaleReapCannotStartOrReplaceNewGeneration() {
        var coordinator = AppServerLifecycleCoordinator()
        _ = coordinator.requestStart(hostPresent: true, permissionReady: true, blocked: false)
        _ = coordinator.requestStop()

        XCTAssertEqual(
            coordinator.reapCompleted(
                generation: 99,
                hostPresent: true,
                permissionReady: true,
                blocked: false
            ),
            []
        )
        XCTAssertEqual(coordinator.reapingGeneration, 1)
    }

    func testReapCompletionRechecksHostPermissionAndTerminalBlock() {
        var coordinator = AppServerLifecycleCoordinator()
        _ = coordinator.requestStart(hostPresent: true, permissionReady: true, blocked: false)
        _ = coordinator.requestStop()

        XCTAssertEqual(
            coordinator.reapCompleted(
                generation: 1,
                hostPresent: false,
                permissionReady: true,
                blocked: false
            ),
            []
        )
        XCTAssertNil(coordinator.activeGeneration)
    }
}
