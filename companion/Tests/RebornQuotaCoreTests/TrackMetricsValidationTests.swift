import XCTest
@testable import RebornQuotaCore

final class TrackMetricsValidationTests: XCTestCase {
    func testAcceptsCrediblePanelMetricsWithMatchingProvenance() {
        XCTAssertEqual(TrackMetricsValidator.failures(
            validMetric(),
            expectation: expectedProvenance()
        ), [])
    }

    func testRejectsMissingPanelShortDurationAndImplausibleCadence() {
        let metric = validMetric(
            panelEnabled: false,
            durationSeconds: 10,
            sampleCount: 1
        )
        let failures = TrackMetricsValidator.failures(metric, expectation: expectedProvenance())

        XCTAssertTrue(failures.contains { $0.contains("panelEnabled") })
        XCTAssertTrue(failures.contains { $0.contains("duration") })
        XCTAssertTrue(failures.contains { $0.contains("cadence") })
    }

    func testRejectsWrongSchemaScenarioModeLayerAndNonfiniteValues() {
        let metric = validMetric(
            schemaVersion: 9,
            scenario: "covered",
            requiresAX: false,
            petLayer: 0,
            maxPanelUpdateMs: .infinity
        )
        let failures = TrackMetricsValidator.failures(metric, expectation: expectedProvenance())

        XCTAssertTrue(failures.contains { $0.contains("schemaVersion") })
        XCTAssertTrue(failures.contains { $0.contains("scenario") })
        XCTAssertTrue(failures.contains { $0.contains("requiresAX") })
        XCTAssertTrue(failures.contains { $0.contains("petLayer") })
        XCTAssertTrue(failures.contains { $0.contains("finite") })
    }

    func testRejectsStableDraggingMetricWhoseHistogramShowsAbsence() {
        let metric = validMetric(
            candidateCountMinimum: 0,
            candidateCountMaximum: 1,
            candidateCountHistogram: ["0": 10, "1": 290],
            stableCandidate: true
        )

        XCTAssertTrue(TrackMetricsValidator.failures(
            metric,
            expectation: expectedProvenance()
        ).contains { $0.contains("stableCandidate") })
    }

    func testRejectsHiddenMetricWithCandidateOrPanelResidue() {
        let metric = validMetric(
            scenario: "pet-hidden",
            durationSeconds: 15,
            sampleCount: 150,
            candidateCountMinimum: 0,
            candidateCountMaximum: 1,
            candidateCountHistogram: ["0": 149, "1": 1],
            stableCandidate: true,
            panelResidueDetected: true
        )
        let hiddenExpectation = TrackMetricsExpectation(
            scenario: "pet-hidden",
            minimumDurationSeconds: 15,
            requiresPanel: true,
            requiresAX: true,
            petLayer: 3
        )
        let failures = TrackMetricsValidator.failures(metric, expectation: hiddenExpectation)

        XCTAssertTrue(failures.contains { $0.contains("stableCandidate") })
        XCTAssertTrue(failures.contains { $0.contains("residue") })
    }

    func testRejectsSpaceMetricWithContradictoryTransition() {
        let metric = validMetric(
            scenario: "ordinary-space-switch",
            durationSeconds: 15,
            sampleCount: 150,
            candidateCountMinimum: 0,
            candidateCountMaximum: 1,
            candidateCountHistogram: ["0": 50, "1": 100],
            stableCandidate: true,
            visibilityTransitions: [
                VisibilityTransition(
                    elapsedSeconds: 1,
                    candidateCount: 0,
                    event: "candidate-visible"
                ),
            ]
        )
        let spaceExpectation = TrackMetricsExpectation(
            scenario: "ordinary-space-switch",
            minimumDurationSeconds: 15,
            requiresPanel: true,
            requiresAX: true,
            petLayer: 3
        )

        XCTAssertTrue(TrackMetricsValidator.failures(
            metric,
            expectation: spaceExpectation
        ).contains { $0.contains("transition") })
    }

    func testAcceptsSpaceMetricWithConsistentTransitions() {
        let metric = validMetric(
            scenario: "ordinary-space-switch",
            durationSeconds: 15,
            sampleCount: 150,
            candidateCountMinimum: 0,
            candidateCountMaximum: 1,
            candidateCountHistogram: ["0": 50, "1": 100],
            stableCandidate: true,
            visibilityTransitions: [
                VisibilityTransition(
                    elapsedSeconds: 0,
                    candidateCount: 1,
                    event: "candidate-visible"
                ),
                VisibilityTransition(
                    elapsedSeconds: 5,
                    candidateCount: 0,
                    event: "candidate-absent"
                ),
                VisibilityTransition(
                    elapsedSeconds: 10,
                    candidateCount: 1,
                    event: "candidate-visible"
                ),
            ]
        )
        let spaceExpectation = TrackMetricsExpectation(
            scenario: "ordinary-space-switch",
            minimumDurationSeconds: 15,
            requiresPanel: true,
            requiresAX: true,
            petLayer: 3
        )

        XCTAssertEqual(TrackMetricsValidator.failures(
            metric,
            expectation: spaceExpectation
        ), [])
    }

    func testRejectsHiddenCandidateHistoryEvenWhenStableFlagIsFalse() {
        let metric = validMetric(
            scenario: "pet-hidden",
            durationSeconds: 15,
            sampleCount: 150,
            candidateCountMinimum: 1,
            candidateCountMaximum: 1,
            candidateCountHistogram: ["1": 150],
            stableCandidate: false
        )
        let hiddenExpectation = TrackMetricsExpectation(
            scenario: "pet-hidden",
            minimumDurationSeconds: 15,
            requiresPanel: true,
            requiresAX: true,
            petLayer: 3
        )

        XCTAssertTrue(TrackMetricsValidator.failures(
            metric,
            expectation: hiddenExpectation
        ).contains { $0.contains("scenario semantics") })
    }

    private func expectedProvenance() -> TrackMetricsExpectation {
        TrackMetricsExpectation(
            scenario: "dragging",
            minimumDurationSeconds: 30,
            requiresPanel: true,
            requiresAX: true,
            petLayer: 3
        )
    }

    private func validMetric(
        schemaVersion: Int = 1,
        scenario: String = "dragging",
        requiresAX: Bool = true,
        panelEnabled: Bool = true,
        durationSeconds: Double = 30,
        sampleCount: Int = 300,
        candidateCountMinimum: Int = 1,
        candidateCountMaximum: Int = 1,
        candidateCountHistogram: [String: Int]? = nil,
        stableCandidate: Bool = true,
        panelResidueDetected: Bool = false,
        petLayer: Int? = 3,
        maxPanelUpdateMs: Double? = 1,
        visibilityTransitions: [VisibilityTransition] = []
    ) -> TrackMetrics {
        let idleWallSeconds = durationSeconds / 3
        let movingWallSeconds = durationSeconds - idleWallSeconds
        return TrackMetrics(
            schemaVersion: schemaVersion,
            scenario: scenario,
            requiresAX: requiresAX,
            axNotificationsReliable: true,
            panelEnabled: panelEnabled,
            durationSeconds: durationSeconds,
            sampleCount: sampleCount,
            candidateCountMinimum: candidateCountMinimum,
            candidateCountMaximum: candidateCountMaximum,
            candidateCountHistogram: candidateCountHistogram ?? ["1": sampleCount],
            stableCandidate: stableCandidate,
            maxMovementDetectionMs: 10,
            maxFollowLatencyMs: 20,
            maxPanelUpdateMs: maxPanelUpdateMs,
            idleCPUSeconds: idleWallSeconds * 0.001,
            idleWallSeconds: idleWallSeconds,
            movingCPUSeconds: movingWallSeconds * 0.001,
            movingWallSeconds: movingWallSeconds,
            idleCPUPercent: 0.1,
            movingCPUPercent: 0.1,
            panelAbovePet: true,
            panelResidueDetected: panelResidueDetected,
            screenIDs: [1],
            petLayer: petLayer,
            visibilityTransitions: visibilityTransitions
        )
    }
}
