import Foundation
import XCTest
@testable import RebornQuotaCore

final class PermissionStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNoAXRequirementNeverRequestsPermission() {
        var machine = PermissionStateMachine(
            requiresAX: false,
            persistence: .empty,
            trusted: false,
            now: now
        )

        XCTAssertEqual(machine.bootstrap(), [.permissionReady])
        XCTAssertEqual(machine.state, .notRequired)
    }

    func testOneTimeRationalePrecedesSystemPrompt() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .empty,
            trusted: false,
            now: now
        )

        XCTAssertEqual(machine.bootstrap(), [.showRationale])
        XCTAssertEqual(machine.rationaleAccepted(), [
            .persist(.init(rationaleShown: true, systemPromptAttempted: true, denialRecorded: false)),
            .requestSystemPrompt,
        ])
    }

    func testPersistedDenialNeverRepeatsPromptAndRechecksAfterThirtySeconds() {
        let persisted = PermissionPersistence(
            rationaleShown: true,
            systemPromptAttempted: true,
            denialRecorded: true,
            recoveryAffordanceShown: true
        )
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: persisted,
            trusted: false,
            now: now
        )

        XCTAssertEqual(machine.bootstrap(), [
            .hideForDegradedMode,
            .scheduleTrustRecheck(after: 30),
        ])
        XCTAssertEqual(machine.recheck(trusted: false, now: now.addingTimeInterval(29)), [])
        XCTAssertEqual(machine.recheck(trusted: false, now: now.addingTimeInterval(30)), [
            .hideForDegradedMode,
            .scheduleTrustRecheck(after: 30),
        ])
        XCTAssertFalse(machine.effectsSoFar.contains(.requestSystemPrompt))
    }

    func testDeniedPromptPersistsAndLaterGrantBecomesReady() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .empty,
            trusted: false,
            now: now
        )
        _ = machine.bootstrap()
        _ = machine.rationaleAccepted()

        XCTAssertEqual(machine.systemPromptCompleted(trusted: false, now: now), [
            .persist(.init(rationaleShown: true, systemPromptAttempted: true, denialRecorded: true)),
            .hideForDegradedMode,
            .scheduleTrustRecheck(after: 30),
        ])
        XCTAssertEqual(machine.recheck(trusted: true, now: now.addingTimeInterval(30)), [
            .persist(.init(rationaleShown: true, systemPromptAttempted: true, denialRecorded: false)),
            .permissionReady,
        ])
        XCTAssertEqual(machine.state, .authorized)
    }

    func testSettingsDeepLinkActionDoesNotPromptAgain() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .init(
                rationaleShown: true,
                systemPromptAttempted: true,
                denialRecorded: true
            ),
            trusted: false,
            now: now
        )
        _ = machine.bootstrap()

        XCTAssertEqual(machine.openSettings(), [.openAccessibilitySettings])
        XCTAssertEqual(
            PermissionStateMachine.accessibilitySettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testPersistedDenialShowsOneTimeReachableRecoveryWithoutReprompting() {
        let persistence = PermissionPersistence(
            rationaleShown: true,
            systemPromptAttempted: true,
            denialRecorded: true,
            recoveryAffordanceShown: false,
            recoveryIdentity: "build-a"
        )
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: persistence,
            trusted: false,
            now: now,
            currentIdentity: "build-a"
        )

        let shown = PermissionPersistence(
            rationaleShown: true,
            systemPromptAttempted: true,
            denialRecorded: true,
            recoveryAffordanceShown: true,
            recoveryIdentity: "build-a"
        )
        XCTAssertEqual(machine.bootstrap(), [
            .hideForDegradedMode,
            .persist(shown),
            .showRecoveryAffordance,
            .scheduleTrustRecheck(after: 30),
        ])
        XCTAssertFalse(machine.effectsSoFar.contains(.requestSystemPrompt))
    }

    func testRecoveryAffordanceIsSuppressedAfterItWasShownForSameIdentity() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .init(
                rationaleShown: true,
                systemPromptAttempted: true,
                denialRecorded: true,
                recoveryAffordanceShown: true,
                recoveryIdentity: "build-a"
            ),
            trusted: false,
            now: now,
            currentIdentity: "build-a"
        )

        XCTAssertEqual(machine.bootstrap(), [
            .hideForDegradedMode,
            .scheduleTrustRecheck(after: 30),
        ])
    }

    func testResignedIdentityGetsRecoveryAffordanceButNeverSystemPromptAgain() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .init(
                rationaleShown: true,
                systemPromptAttempted: true,
                denialRecorded: false,
                recoveryAffordanceShown: true,
                recoveryIdentity: "old-signature"
            ),
            trusted: false,
            now: now,
            currentIdentity: "new-signature"
        )

        let effects = machine.bootstrap()
        XCTAssertTrue(effects.contains(.showRecoveryAffordance))
        XCTAssertFalse(effects.contains(.requestSystemPrompt))
        XCTAssertEqual(machine.persistence.recoveryIdentity, "new-signature")
        XCTAssertTrue(machine.persistence.denialRecorded)
    }

    func testSystemPromptDenialOffersRecoveryOnNextNonpromptRecheck() {
        var machine = PermissionStateMachine(
            requiresAX: true,
            persistence: .empty,
            trusted: false,
            now: now,
            currentIdentity: "build-a"
        )
        _ = machine.bootstrap()
        _ = machine.rationaleAccepted()
        _ = machine.systemPromptCompleted(trusted: false, now: now)

        let effects = machine.recheck(
            trusted: false,
            now: now.addingTimeInterval(30)
        )
        XCTAssertTrue(effects.contains(.showRecoveryAffordance))
        XCTAssertFalse(effects.contains(.requestSystemPrompt))
    }

    func testLegacyPersistenceDecodesWithRecoveryDefaults() throws {
        let data = Data(#"{"rationaleShown":true,"systemPromptAttempted":true,"denialRecorded":true}"#.utf8)

        let decoded = try JSONDecoder().decode(PermissionPersistence.self, from: data)

        XCTAssertFalse(decoded.recoveryAffordanceShown)
        XCTAssertNil(decoded.recoveryIdentity)
    }
}
