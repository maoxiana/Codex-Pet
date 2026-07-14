import XCTest
@testable import RebornQuotaCore

final class EvaluationSnapshotPolicyTests: XCTestCase {
    func testAllEightStructuralSnapshotsAreRequired() {
        XCTAssertEqual(EvaluationSnapshotPolicy.requiredStructuralSnapshots, [
            "pet-hidden.json",
            "pet-visible.json",
            "pet-moved.json",
            "pet-resized.json",
            "notification-open.json",
            "small-codex-window.json",
            "ordinary-space-switch.json",
            "fullscreen-space.json",
        ])
        let existing = Set(
            EvaluationSnapshotPolicy.requiredStructuralSnapshots.filter {
                $0 != "notification-open.json"
            }
        )

        XCTAssertEqual(
            EvaluationSnapshotPolicy.missingSnapshots(
                existingNames: existing,
                screenCountsBySnapshot: [:]
            ),
            ["notification-open.json"]
        )
    }

    func testSecondarySnapshotIsRequiredWhenEvidenceHasTwoScreens() {
        let existing = Set(EvaluationSnapshotPolicy.requiredStructuralSnapshots)

        XCTAssertEqual(
            EvaluationSnapshotPolicy.missingSnapshots(
                existingNames: existing,
                screenCountsBySnapshot: ["pet-visible.json": 2]
            ),
            ["secondary-display.json"]
        )
    }
}
