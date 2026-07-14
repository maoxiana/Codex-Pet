import XCTest
@testable import RebornQuotaCore

final class CodexClientRecoveryPolicyTests: XCTestCase {
    func testTerminalErrorsWaitForHostOrCLIIdentityChange() {
        for error in [
            CodexRateLimitClientError.incompatibleProtocol,
            .executableChanged,
            .alreadyRunning,
        ] {
            XCTAssertEqual(
                CodexClientRecoveryPolicy.action(for: error),
                .waitForHostOrExecutableIdentityChange
            )
        }
    }

    func testAuthenticationUsesConservativeLowFrequencyRetry() {
        XCTAssertEqual(
            CodexClientRecoveryPolicy.action(for: .authenticationRequired),
            .retryAuthenticationAfter(seconds: 60)
        )
    }

    func testTransientErrorsMayUseBackoffAndCancellationStops() {
        XCTAssertEqual(
            CodexClientRecoveryPolicy.action(for: .transportFailure),
            .retryAfterBackoff
        )
        XCTAssertEqual(
            CodexClientRecoveryPolicy.action(for: .timeout(.read)),
            .retryAfterBackoff
        )
        XCTAssertEqual(
            CodexClientRecoveryPolicy.action(for: .cancelled),
            .stop
        )
    }

    func testRetryCoordinatorOwnsOnlyOneTimerAndCleansItUp() {
        var retries = RecoveryRetryCoordinator()

        XCTAssertEqual(retries.schedule(after: 60), [
            .schedule(token: 1, after: 60),
        ])
        XCTAssertEqual(retries.schedule(after: 60), [])
        XCTAssertEqual(retries.cancel(), [.cancel(token: 1)])
        XCTAssertEqual(retries.cancel(), [])
    }

    func testRetryTimerIsTokenProtectedAndRechecksRuntimeEligibility() {
        var retries = RecoveryRetryCoordinator()
        _ = retries.schedule(after: 60)

        XCTAssertFalse(retries.timerFired(token: 99, runtimeEligible: true))
        XCTAssertFalse(retries.timerFired(token: 1, runtimeEligible: false))
        XCTAssertNil(retries.scheduledToken)

        _ = retries.schedule(after: 60)
        XCTAssertTrue(retries.timerFired(token: 2, runtimeEligible: true))
        XCTAssertNil(retries.scheduledToken)
    }
}
