import XCTest
@testable import RebornQuotaCore

final class DiscriminatorTests: XCTestCase {
    func testRequireOnScreenAcceptsOnlyPositiveEvidence() {
        let rule = discriminator(requiresAX: false)

        XCTAssertTrue(rule.matches(window(isOnScreen: true)))
        XCTAssertFalse(rule.matches(window(isOnScreen: false)))
        XCTAssertFalse(rule.matches(window(isOnScreen: nil)))
    }

    func testAXEnvelopeRequireOnScreenAcceptsOnlyPositiveEvidence() {
        let rule = discriminator(requiresAX: true)

        XCTAssertTrue(rule.matchesAXEnvelope(window(isOnScreen: true)))
        XCTAssertFalse(rule.matchesAXEnvelope(window(isOnScreen: false)))
        XCTAssertFalse(rule.matchesAXEnvelope(window(isOnScreen: nil)))
    }

    private func discriminator(requiresAX: Bool) -> PetDiscriminator {
        PetDiscriminator(
            schemaVersion: 1,
            resolvedBundleID: "com.openai.codex",
            layer: 3,
            width: NumericRange(minimum: 300, maximum: 400),
            height: NumericRange(minimum: 300, maximum: 400),
            maximumOrder: 200,
            requireOnScreen: true,
            requiresAX: requiresAX,
            axRequirement: nil,
            evidence: DiscriminatorEvidence(
                hiddenState: "pet-hidden",
                visibleState: "pet-visible",
                excludedStates: ["small-codex-window"],
                visibleCandidateBounds: rect(100, 150, 356, 320),
                visibleCandidateOrder: 183
            )
        )
    }

    private func window(isOnScreen: Bool?) -> WindowSnapshot {
        WindowSnapshot(
            ownerPID: 7_981,
            resolvedBundleID: "com.openai.codex",
            ownerName: "ChatGPT",
            layer: 3,
            bounds: rect(100, 150, 356, 320),
            alpha: 1,
            isOnScreen: isOnScreen,
            sharingState: 1,
            title: nil,
            order: 183
        )
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
