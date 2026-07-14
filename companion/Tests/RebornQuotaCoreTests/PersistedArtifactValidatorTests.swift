import XCTest
@testable import RebornQuotaCore

final class PersistedArtifactValidatorTests: XCTestCase {
    func testRejectsStaleSnapshotVersionAndStateMismatch() {
        let document = WindowSnapshotDocument(
            schemaVersion: 9,
            state: "wrong-state",
            screens: [display()],
            windows: [window()]
        )

        XCTAssertThrowsError(try PersistedArtifactValidator.validateSnapshot(
            document,
            expectedState: "pet-visible"
        ))
    }

    func testRejectsNonfiniteAndInvertedDiscriminatorRanges() {
        let discriminator = PetDiscriminator(
            schemaVersion: 1,
            resolvedBundleID: "com.openai.codex",
            layer: 3,
            width: NumericRange(minimum: .nan, maximum: 200),
            height: NumericRange(minimum: 400, maximum: 300),
            maximumOrder: 10,
            requireOnScreen: true,
            requiresAX: false,
            axRequirement: nil,
            evidence: DiscriminatorEvidence(
                hiddenState: "pet-hidden",
                visibleState: "pet-visible",
                excludedStates: ["small-codex-window"],
                visibleCandidateBounds: rect(10, 20, 356, 320),
                visibleCandidateOrder: 10
            )
        )

        XCTAssertThrowsError(try PersistedArtifactValidator.validateDiscriminator(discriminator))
    }

    func testRejectsStaleAXSchema() {
        let document = AXSnapshotDocument(
            schemaVersion: 1,
            trustedForAccessibility: true,
            coordinateSpace: .cgGlobalTopLeft,
            processes: []
        )

        XCTAssertThrowsError(try PersistedArtifactValidator.validateAXDocument(document))
    }

    private func display() -> DisplayGeometry {
        DisplayGeometry(
            id: 1,
            cgFrame: rect(0, 0, 1_440, 900),
            appKitFrame: rect(0, 0, 1_440, 900),
            appKitVisibleFrame: rect(0, 0, 1_440, 860),
            backingScaleFactor: 2
        )
    }

    private func window() -> WindowSnapshot {
        WindowSnapshot(
            ownerPID: 7_981,
            resolvedBundleID: "com.openai.codex",
            ownerName: "ChatGPT",
            layer: 3,
            bounds: rect(10, 20, 356, 320),
            alpha: 1,
            isOnScreen: true,
            sharingState: 1,
            title: nil,
            order: 10
        )
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
