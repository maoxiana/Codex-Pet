import Foundation
import XCTest
@testable import RebornQuotaCore

final class PetVisualAnchorResolverTests: XCTestCase {
    func testFixtureSelectsApplicationGroupInsteadOfTransparentWindow() throws {
        let document = try loadFixture()

        XCTAssertEqual(
            PetVisualAnchorResolver.resolveCGBounds(
                in: document,
                correlatedWindowBounds: rect(1_698, -602, 356, 320)
            ),
            rect(1_709, -457, 154, 167)
        )
    }

    func testAnchorMovesWithThinkingLayoutInsideStableOuterWindow() {
        let window = rect(100, 200, 356, 320)
        let movedPet = rect(299, 382, 154, 130)
        let document = axDocument(window: window, applicationGroups: [movedPet])

        XCTAssertEqual(
            PetVisualAnchorResolver.resolveCGBounds(
                in: document,
                correlatedWindowBounds: window
            ),
            movedPet
        )
    }

    func testMissingOrAmbiguousVisualAnchorFallsBackAtRuntime() throws {
        let gate = try currentGate()
        let windowDocument = try load(WindowSnapshotDocument.self, named: "pet-visible.json")
        let fixtureDocument = try loadFixture()
        let ambiguousWindow = rect(1_698, -602, 356, 320)
        let ambiguous = axDocument(
            window: ambiguousWindow,
            applicationGroups: [
                rect(1_709, -457, 154, 167),
                rect(1_880, -457, 120, 167),
            ]
        )

        XCTAssertNil(PetVisualAnchorResolver.resolveCGBounds(
            in: ambiguous,
            correlatedWindowBounds: ambiguousWindow
        ))

        guard case .visible(let anchored) = RuntimePetWindowResolver(gate: gate).resolve(
            document: windowDocument,
            axDocument: fixtureDocument
        ) else { return XCTFail("Expected the pet to resolve") }
        XCTAssertEqual(anchored.petFrame, rect(1_709, 1_272, 154, 167))
    }

    func testRejectsUntrustedWrongCoordinateSpaceAndOutOfWindowAnchor() {
        let window = rect(100, 200, 356, 320)
        let outside = rect(500, 400, 154, 130)

        XCTAssertNil(PetVisualAnchorResolver.resolveCGBounds(
            in: axDocument(window: window, applicationGroups: [outside]),
            correlatedWindowBounds: window
        ))
        XCTAssertNil(PetVisualAnchorResolver.resolveCGBounds(
            in: axDocument(
                window: window,
                applicationGroups: [rect(110, 340, 154, 130)],
                trusted: false
            ),
            correlatedWindowBounds: window
        ))
        XCTAssertNil(PetVisualAnchorResolver.resolveCGBounds(
            in: axDocument(
                window: window,
                applicationGroups: [rect(110, 340, 154, 130)],
                coordinateSpace: .appKitGlobalBottomLeft
            ),
            correlatedWindowBounds: window
        ))
    }

    func testTrustedExactCGFallbackUsesMeasuredVisualCardOffset() throws {
        let resolver = RuntimePetWindowResolver(gate: try currentGate())
        let windowDocument = try load(WindowSnapshotDocument.self, named: "pet-visible.json")

        guard case .visible(let location) = resolver.resolve(
            document: windowDocument,
            axDocument: nil,
            accessibilityTrustedFallback: true
        ) else { return XCTFail("Expected trusted exact-CG fallback") }

        XCTAssertEqual(location.petFrame, rect(1_888, 1_275, 154, 130))
        XCTAssertEqual(location.petLayer, 3)
    }

    func testExactCGFallbackStillRequiresRealTrustAndUniqueRecordedSize() throws {
        let resolver = RuntimePetWindowResolver(gate: try currentGate())
        let visible = try load(WindowSnapshotDocument.self, named: "pet-visible.json")

        XCTAssertEqual(
            resolver.resolve(
                document: visible,
                axDocument: nil,
                accessibilityTrustedFallback: false
            ),
            .hidden
        )

        let pet = try XCTUnwrap(visible.windows.first {
            $0.layer == 3 && $0.bounds.width == 356 && $0.bounds.height == 320
        })
        let duplicate = WindowSnapshot(
            windowNumber: (pet.windowNumber ?? 0) + 1,
            ownerPID: pet.ownerPID,
            resolvedBundleID: pet.resolvedBundleID,
            ownerName: pet.ownerName,
            layer: pet.layer,
            bounds: rect(pet.bounds.x + 20, pet.bounds.y + 20, 356, 320),
            alpha: pet.alpha,
            isOnScreen: pet.isOnScreen,
            sharingState: pet.sharingState,
            title: pet.title,
            order: pet.order
        )
        let ambiguous = WindowSnapshotDocument(
            schemaVersion: visible.schemaVersion,
            state: visible.state,
            screens: visible.screens,
            windows: visible.windows + [duplicate]
        )
        XCTAssertEqual(
            resolver.resolve(
                document: ambiguous,
                axDocument: nil,
                accessibilityTrustedFallback: true
            ),
            .hidden
        )
    }

    private func axDocument(
        window: RectValue,
        applicationGroups: [RectValue],
        trusted: Bool = true,
        coordinateSpace: AXCoordinateSpace = .cgGlobalTopLeft
    ) -> AXSnapshotDocument {
        let groups = applicationGroups.map {
            AXNodeSnapshot(
                role: "AXGroup",
                subrole: "AXApplicationGroup",
                identifier: nil,
                bounds: $0,
                childCount: 0,
                children: []
            )
        }
        let petWindow = AXNodeSnapshot(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            identifier: nil,
            bounds: window,
            childCount: groups.count,
            children: groups
        )
        let root = AXNodeSnapshot(
            role: "AXApplication",
            subrole: nil,
            identifier: nil,
            bounds: nil,
            childCount: 1,
            children: [petWindow]
        )
        let notifications = AXWindowStructuralPredicate.rebornObserved
            .requiredWindowNotifications.map {
                AXNotificationProbe(
                    targetRole: "AXWindow",
                    notification: $0,
                    errorCode: 0
                )
            }
        return AXSnapshotDocument(
            schemaVersion: 2,
            trustedForAccessibility: trusted,
            coordinateSpace: coordinateSpace,
            processes: [AXProcessSnapshot(
                pid: 7_981,
                bundleID: "com.openai.codex",
                observerCreationErrorCode: 0,
                notifications: notifications,
                tree: root
            )]
        )
    }

    private func currentGate() throws -> PetWindowGateConfiguration {
        try XCTUnwrap(PetWindowGateConfiguration.decodeValidated(
            from: try data(named: "gate-result.json")
        ))
    }

    private func loadFixture() throws -> AXSnapshotDocument {
        try load(AXSnapshotDocument.self, named: "ax-tree.json")
    }

    private func load<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(named: name))
    }

    private func data(named name: String) throws -> Data {
        try Data(contentsOf: evidenceDirectory.appendingPathComponent(name))
    }

    private var evidenceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qa/window-probe", isDirectory: true)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
