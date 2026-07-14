public struct WindowSnapshotDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: String
    public let screens: [DisplayGeometry]
    public let windows: [WindowSnapshot]

    public init(
        schemaVersion: Int,
        state: String,
        screens: [DisplayGeometry],
        windows: [WindowSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.screens = screens
        self.windows = windows
    }
}

public enum ArtifactValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid([String])

    public var description: String {
        switch self {
        case .invalid(let failures):
            return failures.joined(separator: "; ")
        }
    }
}

public enum PersistedArtifactValidator {
    public static func validateSnapshot(
        _ document: WindowSnapshotDocument,
        expectedState: String? = nil
    ) throws {
        var failures: [String] = []
        if document.schemaVersion != 1 { failures.append("snapshot schemaVersion must be 1") }
        if let expectedState, document.state != expectedState {
            failures.append("snapshot state must be \(expectedState)")
        }
        if document.screens.isEmpty { failures.append("snapshot must contain screen geometry") }
        for screen in document.screens where !validDisplay(screen) {
            failures.append("snapshot contains invalid display geometry")
        }
        for window in document.windows {
            if window.ownerPID <= 0
                || window.resolvedBundleID != "com.openai.codex"
                || window.layer < 0
                || window.order < 0
                || !validRect(window.bounds)
                || window.alpha.map({ !$0.isFinite }) == true {
                failures.append("snapshot contains invalid window metadata")
                break
            }
        }
        try throwIfNeeded(failures)
    }

    public static func validateDiscriminator(_ discriminator: PetDiscriminator) throws {
        var failures: [String] = []
        if discriminator.schemaVersion != 1 {
            failures.append("discriminator schemaVersion must be 1")
        }
        if discriminator.resolvedBundleID != "com.openai.codex" {
            failures.append("discriminator bundle identifier is invalid")
        }
        if discriminator.layer != 3 { failures.append("discriminator layer must be 3") }
        if !validRange(discriminator.width) || !validRange(discriminator.height) {
            failures.append("discriminator ranges must be finite, positive, and ordered")
        }
        if discriminator.maximumOrder < 0 { failures.append("maximumOrder must be nonnegative") }
        if !discriminator.requireOnScreen { failures.append("requireOnScreen must be true") }
        if discriminator.requiresAX != (discriminator.axRequirement != nil) {
            failures.append("requiresAX and axRequirement are inconsistent")
        }
        let evidence = discriminator.evidence
        if evidence.hiddenState != "pet-hidden"
            || evidence.visibleState != "pet-visible"
            || Set(evidence.excludedStates) != Set(["small-codex-window"])
            || !validRect(evidence.visibleCandidateBounds)
            || evidence.visibleCandidateOrder < 0 {
            failures.append("discriminator evidence is invalid")
        }
        if let ax = discriminator.axRequirement {
            if ax.evidence.source.isEmpty
                || ax.evidence.observedPID <= 0
                || ax.evidence.observedLayer != 3
                || ax.evidence.coordinateSpace == .unknown
                || !validRect(ax.evidence.observedBounds) {
                failures.append("AX requirement evidence is invalid")
            }
        }
        try throwIfNeeded(failures)
    }

    public static func validateAXDocument(
        _ document: AXSnapshotDocument,
        requireTrusted: Bool = true
    ) throws {
        var failures: [String] = []
        if document.schemaVersion != 2 { failures.append("AX schemaVersion must be 2") }
        if document.coordinateSpace == .unknown { failures.append("AX coordinate space is unknown") }
        if requireTrusted, !document.trustedForAccessibility {
            failures.append("AX document is not trusted")
        }
        if requireTrusted, document.processes.isEmpty {
            failures.append("AX document has no process evidence")
        }
        for process in document.processes {
            if process.pid <= 0 || process.bundleID != "com.openai.codex" {
                failures.append("AX process identity is invalid")
            }
            if let tree = process.tree, !validAXNode(tree) {
                failures.append("AX tree geometry/completeness metadata is invalid")
            }
        }
        try throwIfNeeded(failures)
    }

    private static func validAXNode(_ node: AXNodeSnapshot) -> Bool {
        if let bounds = node.bounds, !validNonnegativeRect(bounds) { return false }
        if node.childCount < 0 { return false }
        if node.childrenComplete
            && (!node.childrenReadSucceeded
                || node.childCount != node.children.count
                || !node.children.allSatisfy(\.subtreeIsComplete)) {
            return false
        }
        return node.children.allSatisfy(validAXNode)
    }

    private static func validRange(_ range: NumericRange) -> Bool {
        range.minimum.isFinite
            && range.maximum.isFinite
            && range.minimum > 0
            && range.maximum >= range.minimum
    }

    private static func validDisplay(_ display: DisplayGeometry) -> Bool {
        validRect(display.cgFrame)
            && validRect(display.appKitFrame)
            && validRect(display.appKitVisibleFrame)
            && display.backingScaleFactor.isFinite
            && display.backingScaleFactor > 0
    }

    private static func validRect(_ rect: RectValue) -> Bool {
        rect.x.isFinite
            && rect.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private static func validNonnegativeRect(_ rect: RectValue) -> Bool {
        rect.x.isFinite
            && rect.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 0
            && rect.height >= 0
    }

    private static func throwIfNeeded(_ failures: [String]) throws {
        if !failures.isEmpty { throw ArtifactValidationError.invalid(failures) }
    }
}
