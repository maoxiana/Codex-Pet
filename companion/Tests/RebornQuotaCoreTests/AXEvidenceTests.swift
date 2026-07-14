import Foundation
import XCTest
@testable import RebornQuotaCore

final class AXEvidenceTests: XCTestCase {
    func testObserverRegistrationStabilityRequiresBoundsToRemainWithinCorrelationTolerance() {
        let captured = RectValue(x: 100, y: 200, width: 356, height: 320)
        XCTAssertTrue(AXRegistrationStabilityPolicy.isStable(
            captured: captured,
            current: RectValue(x: 101.9, y: 198.1, width: 357.9, height: 318.1),
            tolerance: 2
        ))
        XCTAssertFalse(AXRegistrationStabilityPolicy.isStable(
            captured: captured,
            current: RectValue(x: 102.1, y: 200, width: 356, height: 320),
            tolerance: 2
        ))
        XCTAssertFalse(AXRegistrationStabilityPolicy.isStable(
            captured: captured,
            current: nil,
            tolerance: 2
        ))
    }

    func testTraversalBudgetRejectsHighFanOutBeforeEnqueue() throws {
        var budget = AXTraversalBudget(limit: 512)

        XCTAssertThrowsError(try budget.reserve(513)) { error in
            XCTAssertEqual(error as? AXEvidenceError, .traversalLimitExceeded(512))
        }
        XCTAssertEqual(budget.remaining, 512)
        try budget.reserve(512)
        XCTAssertEqual(budget.remaining, 0)
    }

    func testNonSuccessZeroChildCountFailsClosed() {
        var budget = AXTraversalBudget(limit: 512)

        XCTAssertThrowsError(try AXBoundedChildCountPolicy.reserve(
            status: .failure(-25_204),
            reportedCount: 0,
            budget: &budget
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .attributeReadFailed("AXChildren"))
        }
        XCTAssertEqual(budget.remaining, 512)
    }

    func testExplicitNoValueIsAcceptedAsEmptyChildren() throws {
        var budget = AXTraversalBudget(limit: 512)

        XCTAssertEqual(try AXBoundedChildCountPolicy.reserve(
            status: .noValue,
            reportedCount: 0,
            budget: &budget
        ), 0)
        XCTAssertEqual(budget.remaining, 512)
    }

    func testCandidateHighFanOutFailsBeforeTraversalQueueCanGrowPastLimit() {
        let children = (0..<513).map { _ in
            AXNodeSnapshot(
                role: "AXGroup",
                subrole: nil,
                identifier: nil,
                bounds: nil,
                childCount: 0,
                children: []
            )
        }
        let candidate = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: children.count,
            children: children
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [candidate], notificationWindowCount: 1),
            predicate: .rebornObserved,
            descendantLimitPerWindow: 512
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .traversalLimitExceeded(512))
        }
    }

    func testSelectsUniqueStandardWindowWithoutControlButtonDescendants() throws {
        let selection = try AXEvidenceValidator.selectUniqueWindow(
            in: trustedDocument(),
            predicate: .rebornObserved
        )

        XCTAssertEqual(selection.pid, 7_981)
        XCTAssertEqual(selection.bounds, rect(1_646, -637, 356, 320))
    }

    func testDirectWindowSelectionIgnoresLargeMenuTreeAndEarlyExitsMainWindow() throws {
        var deepUnrelatedTree = AXNodeSnapshot(
            role: "AXGroup",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: 0,
            children: []
        )
        for _ in 0..<2_000 {
            deepUnrelatedTree = AXNodeSnapshot(
                role: "AXGroup",
                subrole: nil,
                identifier: nil,
                bounds: nil,
                childCount: 1,
                children: [deepUnrelatedTree]
            )
        }
        let menu = AXNodeSnapshot(
            role: "AXMenuBar",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: 1,
            children: [deepUnrelatedTree]
        )
        let main = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(0, 0, 1_824, 1_084),
            childCount: 2,
            children: [
                deepUnrelatedTree,
                AXNodeSnapshot(
                    role: "AXButton",
                    subrole: "AXCloseButton",
                    identifier: nil,
                    bounds: nil,
                    childCount: 0,
                    children: []
                ),
            ]
        )
        let document = document(
            rootChildren: [menu, petWindow(bounds: rect(10, 20, 356, 320)), main],
            notificationWindowCount: 2
        )

        let selection = try AXEvidenceValidator.selectUniqueWindow(
            in: document,
            predicate: .rebornObserved,
            descendantLimitPerWindow: 16
        )

        XCTAssertEqual(selection.bounds, rect(10, 20, 356, 320))
    }

    func testRejectsUntrustedTree() {
        var document = trustedDocument()
        document = AXSnapshotDocument(
            schemaVersion: document.schemaVersion,
            trustedForAccessibility: false,
            processes: document.processes
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document,
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .notTrusted)
        }
    }

    func testRejectsAmbiguousControlLessStandardWindows() {
        let first = petWindow(bounds: rect(10, 20, 356, 320))
        let second = petWindow(bounds: rect(40, 50, 356, 320))
        let document = document(windows: [first, second], notificationWindowCount: 2)

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document,
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .candidateCount(2))
        }
    }

    func testRejectsTreeWithoutReliableWindowNotifications() {
        let document = document(
            windows: [petWindow(bounds: rect(10, 20, 356, 320)), mainWindow()],
            notificationWindowCount: 0
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document,
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .notificationSupportMissing("AXMoved"))
        }
    }

    func testRejectsSameSizeWindowAtDifferentOrigin() {
        let selection = AXWindowSelection(
            pid: 7_981,
            bounds: rect(1_646, -637, 356, 320),
            coordinateSpace: .cgGlobalTopLeft
        )
        let windows = [
            window(pid: 7_981, bounds: rect(676, -300, 84, 77), order: 18),
            window(pid: 7_981, bounds: rect(1_774, -1_001, 356, 320), order: 143),
            window(pid: 9_999, bounds: rect(1_646, -637, 356, 320), order: 1),
        ]

        XCTAssertThrowsError(try AXEvidenceValidator.correlate(
            selection: selection,
            with: windows,
            expectedLayer: 3,
            screens: screens()
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .correlationCount(0))
        }
    }

    func testCorrelatesFullBoundsAfterCoordinateNormalization() throws {
        let selection = AXWindowSelection(
            pid: 7_981,
            bounds: rect(100, 550, 320, 200),
            coordinateSpace: .appKitGlobalBottomLeft
        )
        let target = window(pid: 7_981, bounds: rect(100, 150, 320, 200), order: 143)

        XCTAssertEqual(try AXEvidenceValidator.correlate(
            selection: selection,
            with: [target],
            expectedLayer: 3,
            screens: screens()
        ), target)
    }

    func testRejectsExactBoundsOnWrongLayer() {
        let selection = AXWindowSelection(
            pid: 7_981,
            bounds: rect(100, 150, 320, 200),
            coordinateSpace: .cgGlobalTopLeft
        )
        let wrongLayer = window(
            pid: 7_981,
            bounds: rect(100, 150, 320, 200),
            order: 143,
            layer: 0
        )

        XCTAssertThrowsError(try AXEvidenceValidator.correlate(
            selection: selection,
            with: [wrongLayer],
            expectedLayer: 3,
            screens: screens()
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .correlationCount(0))
        }
    }

    func testRejectsAmbiguousAXCGCorrelation() {
        let selection = AXWindowSelection(
            pid: 7_981,
            bounds: rect(1_646, -637, 356, 320),
            coordinateSpace: .cgGlobalTopLeft
        )
        let windows = [
            window(pid: 7_981, bounds: rect(1_646, -637, 356, 320), order: 1),
            window(pid: 7_981, bounds: rect(1_646, -637, 356, 320), order: 2),
        ]

        XCTAssertThrowsError(try AXEvidenceValidator.correlate(
            selection: selection,
            with: windows,
            expectedLayer: 3,
            screens: screens()
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .correlationCount(2))
        }
    }

    func testRejectsTruncatedCandidateTree() {
        let truncated = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: 1,
            children: [],
            childrenComplete: false
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [truncated], notificationWindowCount: 1),
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .incompleteTraversal)
        }
    }

    func testRejectsChildCountMismatch() {
        let incomplete = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: 2,
            children: [AXNodeSnapshot(
                role: "AXGroup",
                subrole: nil,
                identifier: nil,
                bounds: nil,
                childCount: 0,
                children: []
            )]
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [incomplete], notificationWindowCount: 1),
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .incompleteTraversal)
        }
    }

    func testRejectsFailedStructuralAttributeRead() {
        let unreadable = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: 0,
            children: [],
            subroleReadSucceeded: false
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [unreadable], notificationWindowCount: 1),
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .attributeReadFailed("AXSubrole"))
        }
    }

    func testRejectsFailedChildrenAttributeRead() {
        let unreadable = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: 0,
            children: [],
            childrenReadSucceeded: false,
            childrenComplete: false
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [unreadable], notificationWindowCount: 1),
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .incompleteTraversal)
        }
    }

    func testLegacyCaptureWithoutCompletenessFieldsFailsClosed() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "trustedForAccessibility": true,
          "processes": [{
            "pid": 7981,
            "bundleID": "com.openai.codex",
            "observerCreationErrorCode": 0,
            "notifications": [],
            "tree": {
              "role": "AXApplication",
              "childCount": 1,
              "children": [{
                "role": "AXWindow",
                "subrole": "AXStandardWindow",
                "bounds": {"x": 10, "y": 20, "width": 356, "height": 320},
                "childCount": 0,
                "children": []
              }]
            }
          }]
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(AXSnapshotDocument.self, from: data)

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: legacy,
            predicate: .rebornObserved
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .attributeReadFailed("AXWindows"))
        }
    }

    func testRejectsCandidateThatExceedsPerWindowCap() {
        let leaf = AXNodeSnapshot(
            role: "AXGroup",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: 0,
            children: []
        )
        let middle = AXNodeSnapshot(
            role: "AXGroup",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: 1,
            children: [leaf]
        )
        let window = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(10, 20, 356, 320),
            childCount: 1,
            children: [middle]
        )

        XCTAssertThrowsError(try AXEvidenceValidator.selectUniqueWindow(
            in: document(windows: [window], notificationWindowCount: 1),
            predicate: .rebornObserved,
            descendantLimitPerWindow: 1
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .traversalLimitExceeded(1))
        }
    }

    func testGateValidationPropagatesAXRequirement() throws {
        let requirement = observedRequirement(predicate: .rebornObserved)
        let discriminator = discriminator(requirement: requirement)

        XCTAssertTrue(try AXGateValidator.validate(
            discriminator: discriminator,
            axDocument: trustedDocument(),
            visibleWindows: [window(
                pid: 7_981,
                bounds: rect(1_646, -637, 356, 320),
                order: 143
            )],
            screens: screens()
        ))
        XCTAssertTrue(discriminator.matchesAXEnvelope(
            window(pid: 7_981, bounds: rect(1_452, -739, 356, 320), order: 999)
        ))
    }

    func testGateRejectsPredicateThatDoesNotMatchObservedStructure() {
        let unsafePredicate = AXWindowStructuralPredicate(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            forbiddenDescendantSubroles: [],
            requiredWindowNotifications: ["AXMoved", "AXResized", "AXUIElementDestroyed"]
        )
        let discriminator = discriminator(
            requirement: observedRequirement(predicate: unsafePredicate)
        )

        XCTAssertThrowsError(try AXGateValidator.validate(
            discriminator: discriminator,
            axDocument: trustedDocument(),
            visibleWindows: [],
            screens: screens()
        )) { error in
            XCTAssertEqual(error as? AXEvidenceError, .predicateMismatch)
        }
    }

    private func observedRequirement(
        predicate: AXWindowStructuralPredicate
    ) -> AXRequirement {
        AXRequirement(
            predicate: predicate,
            evidence: AXRequirementEvidence(
                source: "ax-tree.json",
                observedPID: 7_981,
                observedBounds: rect(1_646, -637, 356, 320),
                observedLayer: 3,
                coordinateSpace: .cgGlobalTopLeft,
                successfulNotifications: ["AXMoved", "AXResized", "AXUIElementDestroyed"]
            )
        )
    }

    private func discriminator(requirement: AXRequirement) -> PetDiscriminator {
        PetDiscriminator(
            schemaVersion: 1,
            resolvedBundleID: "com.openai.codex",
            layer: 3,
            width: NumericRange(minimum: 200, maximum: 500),
            height: NumericRange(minimum: 200, maximum: 500),
            maximumOrder: 200,
            requireOnScreen: true,
            requiresAX: true,
            axRequirement: requirement,
            evidence: DiscriminatorEvidence(
                hiddenState: "pet-hidden",
                visibleState: "pet-visible",
                excludedStates: [],
                visibleCandidateBounds: rect(1_646, -637, 356, 320),
                visibleCandidateOrder: 143
            )
        )
    }

    private func trustedDocument() -> AXSnapshotDocument {
        document(
            windows: [
                petWindow(bounds: rect(1_646, -637, 356, 320)),
                mainWindow(),
            ],
            notificationWindowCount: 2
        )
    }

    private func document(
        windows: [AXNodeSnapshot],
        notificationWindowCount: Int
    ) -> AXSnapshotDocument {
        document(rootChildren: windows, notificationWindowCount: notificationWindowCount)
    }

    private func document(
        rootChildren: [AXNodeSnapshot],
        notificationWindowCount: Int
    ) -> AXSnapshotDocument {
        let notificationNames = ["AXMoved", "AXResized", "AXUIElementDestroyed"]
        let notifications = notificationNames.flatMap { name in
            (0..<notificationWindowCount).map { _ in
                AXNotificationProbe(targetRole: "AXWindow", notification: name, errorCode: 0)
            }
        }
        let root = AXNodeSnapshot(
            role: "AXApplication",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: rootChildren.count,
            children: rootChildren
        )
        return AXSnapshotDocument(
            schemaVersion: 2,
            trustedForAccessibility: true,
            coordinateSpace: .cgGlobalTopLeft,
            processes: [
                AXProcessSnapshot(
                    pid: 7_981,
                    bundleID: "com.openai.codex",
                    observerCreationErrorCode: 0,
                    notifications: notifications,
                    tree: root
                ),
            ]
        )
    }

    private func petWindow(bounds: RectValue) -> AXNodeSnapshot {
        let group = AXNodeSnapshot(
            role: "AXGroup",
            subrole: nil,
            identifier: nil,
            bounds: bounds,
            childCount: 0,
            children: []
        )
        return AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: bounds,
            childCount: 1,
            children: [group]
        )
    }

    private func mainWindow() -> AXNodeSnapshot {
        let controls = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton"].map {
            AXNodeSnapshot(
                role: "AXButton",
                subrole: $0,
                identifier: nil,
                bounds: nil,
                childCount: 0,
                children: []
            )
        }
        return AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: rect(127, -1_326, 1_824, 1_084),
            childCount: controls.count,
            children: controls
        )
    }

    private func window(
        pid: Int32,
        bounds: RectValue,
        order: Int,
        layer: Int = 3
    ) -> WindowSnapshot {
        WindowSnapshot(
            ownerPID: pid,
            resolvedBundleID: "com.openai.codex",
            ownerName: "ChatGPT",
            layer: layer,
            bounds: bounds,
            alpha: 1,
            isOnScreen: true,
            sharingState: 1,
            title: nil,
            order: order
        )
    }

    private func screens() -> [DisplayGeometry] {
        [
            DisplayGeometry(
                id: 1,
                cgFrame: rect(0, 0, 1_440, 900),
                appKitFrame: rect(0, 0, 1_440, 900),
                appKitVisibleFrame: rect(0, 0, 1_440, 900),
                backingScaleFactor: 2
            ),
            DisplayGeometry(
                id: 2,
                cgFrame: rect(-220, -1_440, 2_560, 1_440),
                appKitFrame: rect(-220, 900, 2_560, 1_440),
                appKitVisibleFrame: rect(-220, 900, 2_560, 1_440),
                backingScaleFactor: 2
            ),
        ]
    }

    private func rect(
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
