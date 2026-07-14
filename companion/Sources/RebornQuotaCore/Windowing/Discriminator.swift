public struct NumericRange: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ value: Double) -> Bool {
        value >= minimum && value <= maximum
    }
}

public struct DiscriminatorEvidence: Codable, Equatable, Sendable {
    public let hiddenState: String
    public let visibleState: String
    public let excludedStates: [String]
    public let visibleCandidateBounds: RectValue
    public let visibleCandidateOrder: Int

    public init(
        hiddenState: String,
        visibleState: String,
        excludedStates: [String],
        visibleCandidateBounds: RectValue,
        visibleCandidateOrder: Int
    ) {
        self.hiddenState = hiddenState
        self.visibleState = visibleState
        self.excludedStates = excludedStates
        self.visibleCandidateBounds = visibleCandidateBounds
        self.visibleCandidateOrder = visibleCandidateOrder
    }
}

public struct PetDiscriminator: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let resolvedBundleID: String
    public let layer: Int
    public let width: NumericRange
    public let height: NumericRange
    public let maximumOrder: Int
    public let requireOnScreen: Bool
    public let requiresAX: Bool
    public let axRequirement: AXRequirement?
    public let evidence: DiscriminatorEvidence

    public init(
        schemaVersion: Int,
        resolvedBundleID: String,
        layer: Int,
        width: NumericRange,
        height: NumericRange,
        maximumOrder: Int,
        requireOnScreen: Bool,
        requiresAX: Bool,
        axRequirement: AXRequirement?,
        evidence: DiscriminatorEvidence
    ) {
        self.schemaVersion = schemaVersion
        self.resolvedBundleID = resolvedBundleID
        self.layer = layer
        self.width = width
        self.height = height
        self.maximumOrder = maximumOrder
        self.requireOnScreen = requireOnScreen
        self.requiresAX = requiresAX
        self.axRequirement = axRequirement
        self.evidence = evidence
    }

    public func matches(_ window: WindowSnapshot) -> Bool {
        window.resolvedBundleID == resolvedBundleID
            && window.layer == layer
            && width.contains(window.bounds.width)
            && height.contains(window.bounds.height)
            && window.order <= maximumOrder
            && (!requireOnScreen || window.isOnScreen == true)
    }

    public func matchesAXEnvelope(_ window: WindowSnapshot) -> Bool {
        guard requiresAX else { return matches(window) }
        return window.resolvedBundleID == resolvedBundleID
            && window.layer == layer
            && width.contains(window.bounds.width)
            && height.contains(window.bounds.height)
            && (!requireOnScreen || window.isOnScreen == true)
    }
}
