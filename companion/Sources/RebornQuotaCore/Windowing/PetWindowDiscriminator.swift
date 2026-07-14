import Foundation

public struct PetGateBehaviorEvidence: Codable, Equatable, Sendable {
    public let snapshot: String
    public let available: Bool
    public let candidateCount: Int?
}

public enum PetPerformanceStatus: Equatable, Sendable {
    case verified
    case deferred(note: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

public struct PetWindowGateConfiguration: Equatable, Sendable {
    public let schemaVersion: Int
    public let petLayer: Int
    public let requiresAX: Bool
    public let discriminator: PetDiscriminator
    public let performanceStatus: PetPerformanceStatus
    public let behaviorEvidence: [PetGateBehaviorEvidence]

    public static func decodeValidated(from data: Data) -> Self? {
        guard let raw = try? JSONDecoder().decode(RawPetWindowGate.self, from: data),
              raw.schemaVersion == 1,
              raw.passed,
              raw.identificationPassed,
              raw.failures.isEmpty,
              raw.missingSnapshots.isEmpty,
              let discriminator = raw.discriminator,
              let petLayer = raw.petLayer,
              petLayer == discriminator.layer,
              raw.requiresAX == discriminator.requiresAX,
              (try? PersistedArtifactValidator.validateDiscriminator(discriminator)) != nil,
              behaviorEvidenceIsValid(raw.behaviorEvidence),
              let performanceStatus = performanceStatus(from: raw) else {
            return nil
        }

        return Self(
            schemaVersion: raw.schemaVersion,
            petLayer: petLayer,
            requiresAX: raw.requiresAX,
            discriminator: discriminator,
            performanceStatus: performanceStatus,
            behaviorEvidence: raw.behaviorEvidence
        )
    }

    fileprivate func documentedCandidateCount(for sourceName: String) -> Int? {
        if sourceName == "pet-visible.json"
            || sourceName == "pet-moved.json"
            || sourceName == "pet-resized.json"
            || sourceName == EvaluationSnapshotPolicy.secondaryDisplaySnapshot {
            return 1
        }
        if sourceName == "pet-hidden.json" || sourceName == "small-codex-window.json" {
            return 0
        }
        return behaviorEvidence.first(where: { $0.snapshot == sourceName })?.candidateCount
    }

    private static func behaviorEvidenceIsValid(
        _ observations: [PetGateBehaviorEvidence]
    ) -> Bool {
        let required = Set([
            "notification-open.json",
            "ordinary-space-switch.json",
            "fullscreen-space.json",
        ])
        let names = observations.map(\.snapshot)
        return Set(names) == required
            && Set(names).count == names.count
            && observations.allSatisfy {
                $0.available && $0.candidateCount.map { $0 >= 0 } == true
            }
    }

    private static func performanceStatus(
        from raw: RawPetWindowGate
    ) -> PetPerformanceStatus? {
        if raw.performanceVerified {
            let note = raw.deferralNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.performanceDeferred,
                  note == nil || note == "",
                  raw.missingMetrics.isEmpty,
                  raw.warnings.isEmpty,
                  let maxMovementDetectionMs = raw.maxMovementDetectionMs,
                  let maxFollowLatencyMs = raw.maxFollowLatencyMs,
                  let idleCPUPercent = raw.idleCPUPercent,
                  let movingCPUPercent = raw.movingCPUPercent,
                  PerformanceAcceptancePolicy.accepts(
                      maxMovementDetectionMs: maxMovementDetectionMs,
                      maxFollowLatencyMs: maxFollowLatencyMs,
                      idleCPUPercent: idleCPUPercent,
                      movingCPUPercent: movingCPUPercent
                  ) else {
                return nil
            }
            return .verified
        }

        guard raw.performanceDeferred,
              let note = raw.deferralNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty,
              raw.metrics.allSatisfy({ metric in
                  metric.map { $0.isFinite && $0 >= 0 } ?? true
              }),
              !raw.missingMetrics.isEmpty,
              raw.missingMetrics.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              !raw.warnings.isEmpty,
              raw.warnings.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return nil
        }
        return .deferred(note: note)
    }
}

public struct PetWindowDiscriminator: Sendable {
    public let gate: PetWindowGateConfiguration

    public init(gate: PetWindowGateConfiguration) {
        self.gate = gate
    }

    /// Runtime selection never treats an AX envelope match as authorization by itself.
    /// An AX-required rule must select a unique structural AX window and correlate it
    /// to the same unique CG candidate by PID and complete bounds.
    public func selectRuntimeCandidate(
        in document: WindowSnapshotDocument,
        axDocument: AXSnapshotDocument?
    ) -> WindowSnapshot? {
        guard (try? PersistedArtifactValidator.validateSnapshot(document)) != nil else {
            return nil
        }

        let candidates = envelopeCandidates(in: document)
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }

        guard gate.requiresAX else { return candidate }
        guard let requirement = gate.discriminator.axRequirement,
              let axDocument,
              (try? PersistedArtifactValidator.validateAXDocument(axDocument)) != nil,
              let selection = try? AXEvidenceValidator.selectUniqueWindow(
                  in: axDocument,
                  predicate: requirement.predicate
              ),
              let correlated = try? AXEvidenceValidator.correlate(
                  selection: selection,
                  with: document.windows,
                  expectedLayer: gate.petLayer,
                  screens: document.screens
              ),
              correlated == candidate else {
            return nil
        }
        return candidate
    }

    /// Offline QA only: counts the persisted, evidence-derived CG envelope. It must
    /// not be used as runtime authorization when `requiresAX` is true.
    func observedEnvelopeCandidateCount(in document: WindowSnapshotDocument) -> Int {
        guard (try? PersistedArtifactValidator.validateSnapshot(document)) != nil else {
            return 0
        }
        return envelopeCandidates(in: document).count
    }

    /// Offline QA only: replays a named state that was explicitly accepted by the
    /// gate. Unknown captures (including unclassified smoke) cannot authorize a pet.
    func replayObservedCandidate(
        in document: WindowSnapshotDocument,
        sourceName: String
    ) -> WindowSnapshot? {
        guard (try? PersistedArtifactValidator.validateSnapshot(document)) != nil,
              sourceName == "\(document.state).json",
              gate.documentedCandidateCount(for: sourceName) == 1 else {
            return nil
        }
        let candidates = envelopeCandidates(in: document)
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func envelopeCandidates(in document: WindowSnapshotDocument) -> [WindowSnapshot] {
        document.windows.filter {
            gate.requiresAX
                ? gate.discriminator.matchesAXEnvelope($0)
                : gate.discriminator.matches($0)
        }
    }
}

private struct RawPetWindowGate: Decodable {
    let schemaVersion: Int
    let passed: Bool
    let identificationPassed: Bool
    let performanceVerified: Bool
    let performanceDeferred: Bool
    let deferralNote: String?
    let requiresAX: Bool
    let petLayer: Int?
    let discriminator: PetDiscriminator?
    let maxMovementDetectionMs: Double?
    let maxFollowLatencyMs: Double?
    let idleCPUPercent: Double?
    let movingCPUPercent: Double?
    let missingSnapshots: [String]
    let missingMetrics: [String]
    let failures: [String]
    let warnings: [String]
    let behaviorEvidence: [PetGateBehaviorEvidence]

    var metrics: [Double?] {
        [maxMovementDetectionMs, maxFollowLatencyMs, idleCPUPercent, movingCPUPercent]
    }
}
