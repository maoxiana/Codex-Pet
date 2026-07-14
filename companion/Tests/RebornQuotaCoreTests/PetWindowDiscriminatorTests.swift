import Foundation
import XCTest
@testable import RebornQuotaCore

final class PetWindowDiscriminatorTests: XCTestCase {
    func testBundledGateIsCanonicallyEqualToQASource() throws {
        let source = try JSONSerialization.jsonObject(with: data(named: "gate-result.json"))
        let bundledURL = evidenceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RebornQuotaCompanion/Resources/gate-result.json")
        let bundled = try JSONSerialization.jsonObject(with: Data(contentsOf: bundledURL))

        XCTAssertEqual(source as? NSDictionary, bundled as? NSDictionary)
    }

    func testCurrentGateDecodesAsDeferredAndNeverAsPerformanceVerified() throws {
        let gate = try XCTUnwrap(
            PetWindowGateConfiguration.decodeValidated(from: try data(named: "gate-result.json"))
        )

        XCTAssertEqual(gate.schemaVersion, 1)
        XCTAssertEqual(gate.petLayer, 3)
        XCTAssertTrue(gate.requiresAX)
        XCTAssertEqual(gate.discriminator.layer, gate.petLayer)
        XCTAssertEqual(gate.discriminator.requiresAX, gate.requiresAX)
        XCTAssertEqual(
            gate.performanceStatus,
            .deferred(
                note: "User explicitly deferred additional scenario collection to continue implementation"
            )
        )
        XCTAssertFalse(gate.performanceStatus.isVerified)
    }

    func testInvalidGateMetadataFailsClosed() throws {
        XCTAssertNil(try validatedGate(mutating: { $0["schemaVersion"] = 2 }))
        XCTAssertNil(try validatedGate(mutating: { $0["passed"] = false }))
        XCTAssertNil(try validatedGate(mutating: { $0["identificationPassed"] = false }))
        XCTAssertNil(try validatedGate(mutating: { $0["discriminator"] = NSNull() }))
        XCTAssertNil(try validatedGate(mutating: { $0["petLayer"] = 0 }))
        XCTAssertNil(try validatedGate(mutating: { $0["requiresAX"] = false }))
        XCTAssertNil(try validatedGate(mutating: { $0["deferralNote"] = "  \n" }))
        XCTAssertNil(try validatedGate(mutating: {
            $0["performanceVerified"] = true
            $0["performanceDeferred"] = true
        }))
        XCTAssertNil(try validatedGate(mutating: {
            $0["performanceVerified"] = true
            $0["performanceDeferred"] = false
            $0["deferralNote"] = NSNull()
        }))
    }

    func testVerifiedGateEnforcesEstablishedPerformanceThresholds() throws {
        XCTAssertEqual(try verifiedGate()?.performanceStatus, .verified)

        XCTAssertNil(try verifiedGate(mutating: { $0["maxMovementDetectionMs"] = 100.000_1 }))
        XCTAssertNil(try verifiedGate(mutating: { $0["maxFollowLatencyMs"] = 34.000_1 }))
        XCTAssertNil(try verifiedGate(mutating: { $0["idleCPUPercent"] = 1.000_1 }))
        XCTAssertNil(try verifiedGate(mutating: { $0["movingCPUPercent"] = 5.000_1 }))

        XCTAssertNotNil(try verifiedGate(mutating: {
            $0["maxMovementDetectionMs"] = 100.0
            $0["maxFollowLatencyMs"] = 34.0
        }), "Latency thresholds are inclusive")
        XCTAssertNil(try verifiedGate(mutating: { $0["idleCPUPercent"] = 1.0 }),
                     "Idle CPU must be strictly below 1%")
        XCTAssertNil(try verifiedGate(mutating: { $0["movingCPUPercent"] = 5.0 }),
                     "Moving CPU must be strictly below 5%")
    }

    func testDeferredGateAcceptsProducerCompatiblePartialMetricsWithoutMarkingVerified() throws {
        let partial = try XCTUnwrap(validatedGate(mutating: {
            $0["maxMovementDetectionMs"] = 150.0
            $0["idleCPUPercent"] = 1.2
        }))

        XCTAssertEqual(
            partial.performanceStatus,
            .deferred(
                note: "User explicitly deferred additional scenario collection to continue implementation"
            )
        )
        XCTAssertFalse(partial.performanceStatus.isVerified)
        XCTAssertNil(try validatedGate(mutating: { $0["maxFollowLatencyMs"] = -0.1 }))
        XCTAssertNil(try validatedGate(mutating: { $0["movingCPUPercent"] = -1.0 }))
    }

    func testDeferredGateRejectsContradictoryMissingEvidence() throws {
        XCTAssertNil(try validatedGate(mutating: { $0["missingMetrics"] = [] }))
        XCTAssertNil(try validatedGate(mutating: { $0["warnings"] = [] }))
        XCTAssertNil(try validatedGate(mutating: {
            $0["performanceDeferred"] = false
            $0["deferralNote"] = NSNull()
        }))
    }

    func testEveryAcceptanceSnapshotReplaysItsDocumentedCandidateCount() throws {
        let gate = try currentGate()
        let selector = PetWindowDiscriminator(gate: gate)
        var expectedCounts = [
            "pet-visible.json": 1,
            "pet-moved.json": 1,
            "pet-resized.json": 1,
            "secondary-display.json": 1,
            "pet-hidden.json": 0,
            "small-codex-window.json": 0,
        ]
        for evidence in gate.behaviorEvidence {
            expectedCounts[evidence.snapshot] = try XCTUnwrap(evidence.candidateCount)
        }

        XCTAssertEqual(Set(expectedCounts.keys), Set([
            "pet-visible.json",
            "pet-moved.json",
            "pet-resized.json",
            "secondary-display.json",
            "pet-hidden.json",
            "small-codex-window.json",
            "notification-open.json",
            "ordinary-space-switch.json",
            "fullscreen-space.json",
        ]))

        for (name, expectedCount) in expectedCounts {
            let document = try snapshot(named: name)
            XCTAssertEqual(
                selector.observedEnvelopeCandidateCount(in: document),
                expectedCount,
                name
            )
            let selected = selector.replayObservedCandidate(in: document, sourceName: name)
            XCTAssertEqual(selected == nil ? 0 : 1, expectedCount, name)
        }
    }

    func testUnclassifiedSmokeIsReadButCannotAuthorizeAPetCandidate() throws {
        let selector = PetWindowDiscriminator(gate: try currentGate())
        let document = try snapshot(named: "unclassified-smoke.json")

        XCTAssertEqual(selector.observedEnvelopeCandidateCount(in: document), 1)
        XCTAssertNil(
            selector.replayObservedCandidate(
                in: document,
                sourceName: "unclassified-smoke.json"
            )
        )
    }

    func testRuntimeAXRuleDoesNotDowngradeToCGOnly() throws {
        let selector = PetWindowDiscriminator(gate: try currentGate())
        let visible = try snapshot(named: "pet-visible.json")
        let axDocument = try load(AXSnapshotDocument.self, named: "ax-tree.json")

        XCTAssertNil(selector.selectRuntimeCandidate(in: visible, axDocument: nil))
        XCTAssertNotNil(selector.selectRuntimeCandidate(in: visible, axDocument: axDocument))
    }

    func testRuntimeResolutionSeamHidesMissingAXAndHiddenPet() throws {
        let resolver = RuntimePetWindowResolver(gate: try currentGate())
        let visible = try snapshot(named: "pet-visible.json")
        let hidden = try snapshot(named: "pet-hidden.json")
        let axDocument = try load(AXSnapshotDocument.self, named: "ax-tree.json")

        XCTAssertEqual(resolver.resolve(document: visible, axDocument: nil), .hidden)
        XCTAssertEqual(resolver.resolve(document: hidden, axDocument: axDocument), .hidden)
        guard case .visible(let location) = resolver.resolve(
            document: visible,
            axDocument: axDocument
        ) else { return XCTFail("Expected uniquely correlated visible pet") }
        XCTAssertEqual(location.petLayer, 3)
        XCTAssertEqual(location.screenVisibleFrame.width, 2_560)
    }

    func testRuntimeAmbiguityFailsClosedEvenWithValidAXEvidence() throws {
        let selector = PetWindowDiscriminator(gate: try currentGate())
        let visible = try snapshot(named: "pet-visible.json")
        let axDocument = try load(AXSnapshotDocument.self, named: "ax-tree.json")
        let candidate = try XCTUnwrap(
            visible.windows.first(where: selector.gate.discriminator.matchesAXEnvelope)
        )
        let duplicate = WindowSnapshot(
            windowNumber: (candidate.windowNumber ?? 0) + 10_000,
            ownerPID: candidate.ownerPID,
            resolvedBundleID: candidate.resolvedBundleID,
            ownerName: candidate.ownerName,
            layer: candidate.layer,
            bounds: candidate.bounds,
            alpha: candidate.alpha,
            isOnScreen: candidate.isOnScreen,
            sharingState: candidate.sharingState,
            title: candidate.title,
            order: candidate.order
        )
        let ambiguous = WindowSnapshotDocument(
            schemaVersion: visible.schemaVersion,
            state: visible.state,
            screens: visible.screens,
            windows: visible.windows + [duplicate]
        )

        XCTAssertNil(selector.selectRuntimeCandidate(in: ambiguous, axDocument: axDocument))
        XCTAssertNil(
            selector.replayObservedCandidate(
                in: ambiguous,
                sourceName: "pet-visible.json"
            )
        )
    }

    func testReplayRejectsMalformedSnapshotArtifactBeforeSelection() throws {
        let selector = PetWindowDiscriminator(gate: try currentGate())
        let visible = try snapshot(named: "pet-visible.json")
        let malformed = WindowSnapshotDocument(
            schemaVersion: 2,
            state: visible.state,
            screens: visible.screens,
            windows: visible.windows
        )

        XCTAssertNil(
            selector.replayObservedCandidate(
                in: malformed,
                sourceName: "pet-visible.json"
            )
        )
    }

    private func currentGate() throws -> PetWindowGateConfiguration {
        try XCTUnwrap(
            PetWindowGateConfiguration.decodeValidated(from: try data(named: "gate-result.json"))
        )
    }

    private func validatedGate(
        mutating mutation: (inout [String: Any]) -> Void
    ) throws -> PetWindowGateConfiguration? {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data(named: "gate-result.json"))
                as? [String: Any]
        )
        mutation(&object)
        return PetWindowGateConfiguration.decodeValidated(
            from: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func verifiedGate(
        mutating mutation: (inout [String: Any]) -> Void = { _ in }
    ) throws -> PetWindowGateConfiguration? {
        try validatedGate(mutating: {
            $0["performanceVerified"] = true
            $0["performanceDeferred"] = false
            $0["deferralNote"] = NSNull()
            $0["maxMovementDetectionMs"] = 99.0
            $0["maxFollowLatencyMs"] = 33.0
            $0["idleCPUPercent"] = 0.99
            $0["movingCPUPercent"] = 4.99
            $0["missingMetrics"] = []
            $0["warnings"] = []
            mutation(&$0)
        })
    }

    private func snapshot(named name: String) throws -> WindowSnapshotDocument {
        try load(WindowSnapshotDocument.self, named: name)
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
}
