public struct VisibilityTransition: Codable, Equatable, Sendable {
    public let elapsedSeconds: Double
    public let candidateCount: Int
    public let event: String

    public init(elapsedSeconds: Double, candidateCount: Int, event: String) {
        self.elapsedSeconds = elapsedSeconds
        self.candidateCount = candidateCount
        self.event = event
    }
}

public struct TrackMetrics: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scenario: String
    public let requiresAX: Bool
    public let axNotificationsReliable: Bool?
    public let panelEnabled: Bool
    public let durationSeconds: Double
    public let sampleCount: Int
    public let candidateCountMinimum: Int
    public let candidateCountMaximum: Int
    public let candidateCountHistogram: [String: Int]
    public let stableCandidate: Bool
    public let maxMovementDetectionMs: Double?
    public let maxFollowLatencyMs: Double?
    public let maxPanelUpdateMs: Double?
    public let idleCPUSeconds: Double
    public let idleWallSeconds: Double
    public let movingCPUSeconds: Double
    public let movingWallSeconds: Double
    public let idleCPUPercent: Double?
    public let movingCPUPercent: Double?
    public let panelAbovePet: Bool
    public let panelResidueDetected: Bool
    public let screenIDs: [UInt32]
    public let petLayer: Int?
    public let visibilityTransitions: [VisibilityTransition]

    public init(
        schemaVersion: Int,
        scenario: String,
        requiresAX: Bool,
        axNotificationsReliable: Bool?,
        panelEnabled: Bool,
        durationSeconds: Double,
        sampleCount: Int,
        candidateCountMinimum: Int,
        candidateCountMaximum: Int,
        candidateCountHistogram: [String: Int],
        stableCandidate: Bool,
        maxMovementDetectionMs: Double?,
        maxFollowLatencyMs: Double?,
        maxPanelUpdateMs: Double?,
        idleCPUSeconds: Double,
        idleWallSeconds: Double,
        movingCPUSeconds: Double,
        movingWallSeconds: Double,
        idleCPUPercent: Double?,
        movingCPUPercent: Double?,
        panelAbovePet: Bool,
        panelResidueDetected: Bool,
        screenIDs: [UInt32],
        petLayer: Int?,
        visibilityTransitions: [VisibilityTransition]
    ) {
        self.schemaVersion = schemaVersion
        self.scenario = scenario
        self.requiresAX = requiresAX
        self.axNotificationsReliable = axNotificationsReliable
        self.panelEnabled = panelEnabled
        self.durationSeconds = durationSeconds
        self.sampleCount = sampleCount
        self.candidateCountMinimum = candidateCountMinimum
        self.candidateCountMaximum = candidateCountMaximum
        self.candidateCountHistogram = candidateCountHistogram
        self.stableCandidate = stableCandidate
        self.maxMovementDetectionMs = maxMovementDetectionMs
        self.maxFollowLatencyMs = maxFollowLatencyMs
        self.maxPanelUpdateMs = maxPanelUpdateMs
        self.idleCPUSeconds = idleCPUSeconds
        self.idleWallSeconds = idleWallSeconds
        self.movingCPUSeconds = movingCPUSeconds
        self.movingWallSeconds = movingWallSeconds
        self.idleCPUPercent = idleCPUPercent
        self.movingCPUPercent = movingCPUPercent
        self.panelAbovePet = panelAbovePet
        self.panelResidueDetected = panelResidueDetected
        self.screenIDs = screenIDs
        self.petLayer = petLayer
        self.visibilityTransitions = visibilityTransitions
    }
}

public struct TrackMetricsExpectation: Equatable, Sendable {
    public let scenario: String
    public let minimumDurationSeconds: Double
    public let requiresPanel: Bool
    public let requiresAX: Bool
    public let petLayer: Int

    public init(
        scenario: String,
        minimumDurationSeconds: Double,
        requiresPanel: Bool,
        requiresAX: Bool,
        petLayer: Int
    ) {
        self.scenario = scenario
        self.minimumDurationSeconds = minimumDurationSeconds
        self.requiresPanel = requiresPanel
        self.requiresAX = requiresAX
        self.petLayer = petLayer
    }
}

public enum TrackMetricsValidator {
    public static func failures(
        _ metric: TrackMetrics,
        expectation: TrackMetricsExpectation
    ) -> [String] {
        var failures: [String] = []
        if metric.schemaVersion != 1 {
            failures.append("schemaVersion must be 1")
        }
        if metric.scenario != expectation.scenario {
            failures.append("scenario must be \(expectation.scenario)")
        }
        if metric.requiresAX != expectation.requiresAX {
            failures.append("requiresAX does not match discriminator")
        }
        if metric.requiresAX != (metric.axNotificationsReliable != nil) {
            failures.append("AX notification provenance is inconsistent with requiresAX")
        }
        if metric.petLayer != expectation.petLayer {
            failures.append("petLayer does not match discriminator")
        }
        if expectation.requiresPanel, !metric.panelEnabled {
            failures.append("panelEnabled must be true")
        }
        if !metric.durationSeconds.isFinite
            || metric.durationSeconds < expectation.minimumDurationSeconds {
            failures.append("duration must be at least \(expectation.minimumDurationSeconds) seconds")
        }
        let cadence = metric.durationSeconds > 0
            ? Double(metric.sampleCount) / metric.durationSeconds
            : 0
        if metric.sampleCount <= 0 || !cadence.isFinite || cadence < 5 || cadence > 120 {
            failures.append("sample cadence must be credible and positive")
        }
        if metric.candidateCountMinimum < 0
            || metric.candidateCountMaximum < metric.candidateCountMinimum {
            failures.append("candidate count range is invalid")
        }
        if metric.candidateCountHistogram.values.contains(where: { $0 < 0 })
            || metric.candidateCountHistogram.values.reduce(0, +) != metric.sampleCount {
            failures.append("candidate count histogram does not match sampleCount")
        }
        let histogramCounts = metric.candidateCountHistogram.keys.compactMap(Int.init)
        if histogramCounts.count != metric.candidateCountHistogram.count
            || histogramCounts.contains(where: { $0 < 0 })
            || histogramCounts.min() != metric.candidateCountMinimum
            || histogramCounts.max() != metric.candidateCountMaximum {
            failures.append("candidate count histogram range is invalid")
        }
        let requiredNumbers = [
            metric.durationSeconds,
            metric.idleCPUSeconds,
            metric.idleWallSeconds,
            metric.movingCPUSeconds,
            metric.movingWallSeconds,
        ]
        let optionalNumbers = [
            metric.maxMovementDetectionMs,
            metric.maxFollowLatencyMs,
            metric.maxPanelUpdateMs,
            metric.idleCPUPercent,
            metric.movingCPUPercent,
        ].compactMap { $0 }
        if (requiredNumbers + optionalNumbers).contains(where: { !$0.isFinite || $0 < 0 }) {
            failures.append("metric numeric values must be finite and nonnegative")
        }
        let measuredWall = metric.idleWallSeconds + metric.movingWallSeconds
        if measuredWall <= 0
            || abs(measuredWall - metric.durationSeconds) > max(1, metric.durationSeconds * 0.2) {
            failures.append("measured wall time is inconsistent with duration")
        }
        if !percentMatches(
            seconds: metric.idleCPUSeconds,
            wall: metric.idleWallSeconds,
            percent: metric.idleCPUPercent
        ) || !percentMatches(
            seconds: metric.movingCPUSeconds,
            wall: metric.movingWallSeconds,
            percent: metric.movingCPUPercent
        ) {
            failures.append("CPU percentages are inconsistent with CPU/wall seconds")
        }
        if metric.visibilityTransitions.contains(where: {
            !$0.elapsedSeconds.isFinite
                || $0.elapsedSeconds < 0
                || $0.elapsedSeconds > metric.durationSeconds
                || $0.candidateCount < 0
        }) {
            failures.append("visibility transitions must be finite and nonnegative")
        }
        let scenario = metric.scenario.lowercased()
        let histogramStates = Set(histogramCounts)
        let transitionsAreValid = transitionSemanticsMatch(
            metric.visibilityTransitions,
            histogramStates: histogramStates,
            requireCompleteStateHistory: scenario.contains("space")
        )
        if !transitionsAreValid {
            failures.append("visibility transition semantics contradict candidate history")
        }

        let stableForScenario: Bool
        if scenario.contains("hidden") {
            stableForScenario = metric.candidateCountMinimum == 0
                && metric.candidateCountMaximum == 0
                && histogramStates == [0]
            if metric.panelResidueDetected || !metric.panelAbovePet {
                failures.append("hidden scenario has panel residue or incomplete cleanup")
            }
        } else if scenario.contains("space") {
            stableForScenario = metric.candidateCountMinimum >= 0
                && metric.candidateCountMaximum == 1
                && histogramStates.isSubset(of: [0, 1])
                && transitionsAreValid
        } else {
            stableForScenario = metric.candidateCountMinimum == 1
                && metric.candidateCountMaximum == 1
                && histogramStates == [1]
        }
        if !stableForScenario {
            failures.append("candidate history does not satisfy scenario semantics")
        }
        if metric.stableCandidate != stableForScenario {
            failures.append("stableCandidate contradicts the scenario candidate history")
        }
        return failures
    }

    private static func transitionSemanticsMatch(
        _ transitions: [VisibilityTransition],
        histogramStates: Set<Int>,
        requireCompleteStateHistory: Bool
    ) -> Bool {
        if transitions.isEmpty {
            return !requireCompleteStateHistory
        }
        var previousElapsed = -Double.infinity
        var previousPresence: Bool?
        var transitionStates = Set<Int>()
        for transition in transitions {
            let present = transition.candidateCount == 1
            let expectedEvent = present ? "candidate-visible" : "candidate-absent"
            guard transition.elapsedSeconds >= previousElapsed,
                  transition.event == expectedEvent,
                  previousPresence != present else {
                return false
            }
            previousElapsed = transition.elapsedSeconds
            previousPresence = present
            transitionStates.insert(transition.candidateCount)
        }
        return !requireCompleteStateHistory || transitionStates == histogramStates
    }

    private static func percentMatches(
        seconds: Double,
        wall: Double,
        percent: Double?
    ) -> Bool {
        if wall == 0 { return percent == nil && seconds == 0 }
        guard let percent else { return false }
        let expected = seconds / wall * 100
        return expected.isFinite && abs(expected - percent) <= max(0.001, expected * 0.01)
    }
}
