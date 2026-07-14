import Foundation

public struct AXNodeSnapshot: Codable, Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let identifier: String?
    public let bounds: RectValue?
    public let childCount: Int
    public let children: [AXNodeSnapshot]
    public let roleReadSucceeded: Bool
    public let subroleReadSucceeded: Bool
    public let childrenReadSucceeded: Bool
    public let childrenComplete: Bool

    public init(
        role: String?,
        subrole: String?,
        identifier: String?,
        bounds: RectValue?,
        childCount: Int,
        children: [AXNodeSnapshot],
        roleReadSucceeded: Bool = true,
        subroleReadSucceeded: Bool = true,
        childrenReadSucceeded: Bool = true,
        childrenComplete: Bool = true
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.bounds = bounds
        self.childCount = childCount
        self.children = children
        self.roleReadSucceeded = roleReadSucceeded
        self.subroleReadSucceeded = subroleReadSucceeded
        self.childrenReadSucceeded = childrenReadSucceeded
        self.childrenComplete = childrenComplete
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case subrole
        case identifier
        case bounds
        case childCount
        case children
        case roleReadSucceeded
        case subroleReadSucceeded
        case childrenReadSucceeded
        case childrenComplete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        bounds = try container.decodeIfPresent(RectValue.self, forKey: .bounds)
        childCount = try container.decode(Int.self, forKey: .childCount)
        children = try container.decode([AXNodeSnapshot].self, forKey: .children)
        // Legacy captures did not record read/completeness state and therefore cannot
        // prove the absence of a forbidden descendant.
        roleReadSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .roleReadSucceeded
        ) ?? false
        subroleReadSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .subroleReadSucceeded
        ) ?? false
        childrenReadSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .childrenReadSucceeded
        ) ?? false
        childrenComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .childrenComplete
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(bounds, forKey: .bounds)
        try container.encode(childCount, forKey: .childCount)
        try container.encode(children, forKey: .children)
        try container.encode(roleReadSucceeded, forKey: .roleReadSucceeded)
        try container.encode(subroleReadSucceeded, forKey: .subroleReadSucceeded)
        try container.encode(childrenReadSucceeded, forKey: .childrenReadSucceeded)
        try container.encode(childrenComplete, forKey: .childrenComplete)
    }

    public func containsDescendant(subrole target: String) -> Bool {
        children.contains { child in
            child.subrole == target || child.containsDescendant(subrole: target)
        }
    }

    public var subtreeIsComplete: Bool {
        roleReadSucceeded
            && subroleReadSucceeded
            && childrenReadSucceeded
            && childrenComplete
            && childCount == children.count
            && children.allSatisfy(\.subtreeIsComplete)
    }
}

public struct AXNotificationProbe: Codable, Equatable, Sendable {
    public let targetRole: String?
    public let notification: String
    public let errorCode: Int32

    public init(targetRole: String?, notification: String, errorCode: Int32) {
        self.targetRole = targetRole
        self.notification = notification
        self.errorCode = errorCode
    }
}

public struct AXProcessSnapshot: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String
    public let observerCreationErrorCode: Int32
    public let notifications: [AXNotificationProbe]
    public let tree: AXNodeSnapshot?
    public let windowsReadSucceeded: Bool

    public init(
        pid: Int32,
        bundleID: String,
        observerCreationErrorCode: Int32,
        notifications: [AXNotificationProbe],
        tree: AXNodeSnapshot?,
        windowsReadSucceeded: Bool = true
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.observerCreationErrorCode = observerCreationErrorCode
        self.notifications = notifications
        self.tree = tree
        self.windowsReadSucceeded = windowsReadSucceeded
    }

    private enum CodingKeys: String, CodingKey {
        case pid
        case bundleID
        case observerCreationErrorCode
        case notifications
        case tree
        case windowsReadSucceeded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        observerCreationErrorCode = try container.decode(
            Int32.self,
            forKey: .observerCreationErrorCode
        )
        notifications = try container.decode([AXNotificationProbe].self, forKey: .notifications)
        tree = try container.decodeIfPresent(AXNodeSnapshot.self, forKey: .tree)
        windowsReadSucceeded = try container.decodeIfPresent(
            Bool.self,
            forKey: .windowsReadSucceeded
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(observerCreationErrorCode, forKey: .observerCreationErrorCode)
        try container.encode(notifications, forKey: .notifications)
        try container.encodeIfPresent(tree, forKey: .tree)
        try container.encode(windowsReadSucceeded, forKey: .windowsReadSucceeded)
    }
}

public enum AXCoordinateSpace: String, Codable, Equatable, Sendable {
    case appKitGlobalBottomLeft
    case cgGlobalTopLeft
    case unknown
}

public struct AXSnapshotDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let trustedForAccessibility: Bool
    public let coordinateSpace: AXCoordinateSpace
    public let processes: [AXProcessSnapshot]

    public init(
        schemaVersion: Int,
        trustedForAccessibility: Bool,
        coordinateSpace: AXCoordinateSpace = .cgGlobalTopLeft,
        processes: [AXProcessSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.trustedForAccessibility = trustedForAccessibility
        self.coordinateSpace = coordinateSpace
        self.processes = processes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case trustedForAccessibility
        case coordinateSpace
        case processes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        trustedForAccessibility = try container.decode(
            Bool.self,
            forKey: .trustedForAccessibility
        )
        coordinateSpace = try container.decodeIfPresent(
            AXCoordinateSpace.self,
            forKey: .coordinateSpace
        ) ?? .unknown
        processes = try container.decode([AXProcessSnapshot].self, forKey: .processes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(trustedForAccessibility, forKey: .trustedForAccessibility)
        try container.encode(coordinateSpace, forKey: .coordinateSpace)
        try container.encode(processes, forKey: .processes)
    }
}

public struct AXWindowStructuralPredicate: Codable, Equatable, Sendable {
    public let role: String
    public let subrole: String
    public let forbiddenDescendantSubroles: [String]
    public let requiredWindowNotifications: [String]

    public init(
        role: String,
        subrole: String,
        forbiddenDescendantSubroles: [String],
        requiredWindowNotifications: [String]
    ) {
        self.role = role
        self.subrole = subrole
        self.forbiddenDescendantSubroles = forbiddenDescendantSubroles
        self.requiredWindowNotifications = requiredWindowNotifications
    }

    public static let rebornObserved = AXWindowStructuralPredicate(
        role: "AXWindow",
        subrole: "AXStandardWindow",
        forbiddenDescendantSubroles: [
            "AXCloseButton",
            "AXFullScreenButton",
            "AXMinimizeButton",
        ],
        requiredWindowNotifications: [
            "AXMoved",
            "AXResized",
            "AXUIElementDestroyed",
        ]
    )

    public func matches(_ node: AXNodeSnapshot) -> Bool {
        node.subtreeIsComplete
            && node.role == role
            && node.subrole == subrole
            && forbiddenDescendantSubroles.allSatisfy {
                !node.containsDescendant(subrole: $0)
            }
    }
}

public struct AXRequirementEvidence: Codable, Equatable, Sendable {
    public let source: String
    public let observedPID: Int32
    public let observedBounds: RectValue
    public let observedLayer: Int?
    public let coordinateSpace: AXCoordinateSpace
    public let successfulNotifications: [String]

    public init(
        source: String,
        observedPID: Int32,
        observedBounds: RectValue,
        observedLayer: Int? = nil,
        coordinateSpace: AXCoordinateSpace = .unknown,
        successfulNotifications: [String]
    ) {
        self.source = source
        self.observedPID = observedPID
        self.observedBounds = observedBounds
        self.observedLayer = observedLayer
        self.coordinateSpace = coordinateSpace
        self.successfulNotifications = successfulNotifications
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case observedPID
        case observedBounds
        case observedLayer
        case coordinateSpace
        case successfulNotifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        observedPID = try container.decode(Int32.self, forKey: .observedPID)
        observedBounds = try container.decode(RectValue.self, forKey: .observedBounds)
        observedLayer = try container.decodeIfPresent(Int.self, forKey: .observedLayer)
        coordinateSpace = try container.decodeIfPresent(
            AXCoordinateSpace.self,
            forKey: .coordinateSpace
        ) ?? .unknown
        successfulNotifications = try container.decode(
            [String].self,
            forKey: .successfulNotifications
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(observedPID, forKey: .observedPID)
        try container.encode(observedBounds, forKey: .observedBounds)
        try container.encodeIfPresent(observedLayer, forKey: .observedLayer)
        try container.encode(coordinateSpace, forKey: .coordinateSpace)
        try container.encode(successfulNotifications, forKey: .successfulNotifications)
    }
}

public struct AXRequirement: Codable, Equatable, Sendable {
    public let predicate: AXWindowStructuralPredicate
    public let evidence: AXRequirementEvidence

    public init(predicate: AXWindowStructuralPredicate, evidence: AXRequirementEvidence) {
        self.predicate = predicate
        self.evidence = evidence
    }
}

public struct AXWindowSelection: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bounds: RectValue
    public let coordinateSpace: AXCoordinateSpace

    public init(
        pid: Int32,
        bounds: RectValue,
        coordinateSpace: AXCoordinateSpace = .cgGlobalTopLeft
    ) {
        self.pid = pid
        self.bounds = bounds
        self.coordinateSpace = coordinateSpace
    }
}

public enum AXEvidenceError: Error, Equatable, Sendable, CustomStringConvertible {
    case ambiguousProcessCount(Int)
    case attributeReadFailed(String)
    case candidateCount(Int)
    case coordinateConversionFailed
    case correlationCount(Int)
    case evidenceMismatch
    case incompleteTraversal
    case missingBounds
    case missingDocument
    case missingRequirement
    case notTrusted
    case notificationSupportMissing(String)
    case predicateMismatch
    case traversalLimitExceeded(Int)
    case unknownCoordinateSpace

    public var description: String {
        switch self {
        case .ambiguousProcessCount(let count):
            return "AX evidence contains \(count) matching Codex processes; expected one"
        case .attributeReadFailed(let attribute):
            return "AX structural attribute read failed: \(attribute)"
        case .candidateCount(let count):
            return "AX structural predicate matched \(count) windows; expected exactly one"
        case .coordinateConversionFailed:
            return "AX/CG bounds could not be normalized using snapshot screen geometry"
        case .correlationCount(let count):
            return "AX/CG bounds and PID correlation matched \(count) windows; expected exactly one"
        case .evidenceMismatch:
            return "AX requirement evidence does not match the complete aligned capture"
        case .incompleteTraversal:
            return "AX structural capture is incomplete and cannot prove descendant absence"
        case .missingBounds:
            return "AX structural candidate has no geometry"
        case .missingDocument:
            return "AX evidence is required but ax-tree.json is missing"
        case .missingRequirement:
            return "Discriminator requires AX but has no structural requirement"
        case .notTrusted:
            return "AX evidence is not authorized"
        case .notificationSupportMissing(let notification):
            return "AX window notification is not reliably supported: \(notification)"
        case .predicateMismatch:
            return "AX discriminator predicate does not match the authorized Reborn structure"
        case .traversalLimitExceeded(let limit):
            return "AX direct-window descendant scan exceeded its per-window limit of \(limit)"
        case .unknownCoordinateSpace:
            return "AX capture coordinate space is unknown"
        }
    }
}

public struct AXTraversalBudget: Equatable, Sendable {
    public let limit: Int
    public private(set) var remaining: Int

    public init(limit: Int) {
        self.limit = max(0, limit)
        self.remaining = max(0, limit)
    }

    public mutating func reserve(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw AXEvidenceError.traversalLimitExceeded(limit)
        }
        remaining -= count
    }
}

public enum AXAttributeReadStatus: Equatable, Sendable {
    case success
    case noValue
    case failure(Int32)
}

public enum AXBoundedChildCountPolicy {
    @discardableResult
    public static func reserve(
        status: AXAttributeReadStatus,
        reportedCount: Int,
        budget: inout AXTraversalBudget
    ) throws -> Int {
        switch status {
        case .noValue:
            return 0
        case .failure:
            throw AXEvidenceError.attributeReadFailed("AXChildren")
        case .success:
            guard reportedCount >= 0 else {
                throw AXEvidenceError.attributeReadFailed("AXChildren")
            }
            guard reportedCount > 0 else { return 0 }
            try budget.reserve(reportedCount)
            return reportedCount
        }
    }
}

public enum AXEvidenceValidator {
    private static let codexBundleID = "com.openai.codex"

    public static func selectUniqueWindow(
        in document: AXSnapshotDocument,
        predicate: AXWindowStructuralPredicate,
        descendantLimitPerWindow: Int = 512
    ) throws -> AXWindowSelection {
        guard document.trustedForAccessibility else {
            throw AXEvidenceError.notTrusted
        }
        let processes = document.processes.filter { $0.bundleID == codexBundleID }
        guard processes.count == 1, let process = processes.first else {
            throw AXEvidenceError.ambiguousProcessCount(processes.count)
        }
        guard process.windowsReadSucceeded else {
            throw AXEvidenceError.attributeReadFailed("AXWindows")
        }
        guard let root = process.tree,
              root.childrenReadSucceeded,
              root.childCount == root.children.count else {
            throw AXEvidenceError.incompleteTraversal
        }

        let directWindows = root.children
        var candidates: [AXNodeSnapshot] = []
        for window in directWindows {
            if try matchesWithinLimit(
                window,
                predicate: predicate,
                descendantLimit: descendantLimitPerWindow
            ) {
                candidates.append(window)
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw AXEvidenceError.candidateCount(candidates.count)
        }
        guard let bounds = candidate.bounds else {
            throw AXEvidenceError.missingBounds
        }

        let windowCount = directWindows.filter {
            $0.role == predicate.role && $0.subrole == predicate.subrole
        }.count
        for notification in predicate.requiredWindowNotifications {
            let successes = process.notifications.filter {
                $0.targetRole == predicate.role
                    && $0.notification == notification
                    && $0.errorCode == 0
            }.count
            guard successes >= windowCount else {
                throw AXEvidenceError.notificationSupportMissing(notification)
            }
        }
        return AXWindowSelection(
            pid: process.pid,
            bounds: bounds,
            coordinateSpace: document.coordinateSpace
        )
    }

    public static func correlate(
        selection: AXWindowSelection,
        with windows: [WindowSnapshot],
        expectedLayer: Int,
        screens: [DisplayGeometry],
        tolerance: Double = 2
    ) throws -> WindowSnapshot {
        let normalizedAXBounds: RectValue
        switch selection.coordinateSpace {
        case .cgGlobalTopLeft:
            guard let converted = try? CoordinateConverter.convert(
                cgWindowBounds: selection.bounds,
                screens: screens
            ) else {
                throw AXEvidenceError.coordinateConversionFailed
            }
            normalizedAXBounds = converted.appKitBounds
        case .appKitGlobalBottomLeft:
            guard screens.contains(where: {
                $0.appKitFrame.intersectionArea(with: selection.bounds) > 0
            }) else {
                throw AXEvidenceError.coordinateConversionFailed
            }
            normalizedAXBounds = selection.bounds
        case .unknown:
            throw AXEvidenceError.unknownCoordinateSpace
        }

        let eligible = windows.filter {
            $0.ownerPID == selection.pid && $0.layer == expectedLayer
        }
        var exact: [WindowSnapshot] = []
        for window in eligible {
            guard let normalizedCG = try? CoordinateConverter.convert(
                cgWindowBounds: window.bounds,
                screens: screens
            ).appKitBounds else {
                throw AXEvidenceError.coordinateConversionFailed
            }
            if approximatelyEqual(
                normalizedCG,
                normalizedAXBounds,
                tolerance: tolerance
            ) {
                exact.append(window)
            }
        }
        guard exact.count == 1, let result = exact.first else {
            throw AXEvidenceError.correlationCount(exact.count)
        }
        return result
    }

    private static func matchesWithinLimit(
        _ window: AXNodeSnapshot,
        predicate: AXWindowStructuralPredicate,
        descendantLimit: Int
    ) throws -> Bool {
        guard window.roleReadSucceeded else {
            throw AXEvidenceError.attributeReadFailed("AXRole")
        }
        guard window.subroleReadSucceeded else {
            throw AXEvidenceError.attributeReadFailed("AXSubrole")
        }
        guard window.role == predicate.role, window.subrole == predicate.subrole else {
            return false
        }
        guard window.childrenReadSucceeded,
              window.childCount == window.children.count else {
            throw AXEvidenceError.incompleteTraversal
        }
        var budget = AXTraversalBudget(limit: descendantLimit)
        try budget.reserve(window.children.count)
        var queue = window.children
        var index = 0
        while index < queue.count {
            let node = queue[index]
            index += 1
            guard node.roleReadSucceeded else {
                throw AXEvidenceError.attributeReadFailed("AXRole")
            }
            guard node.subroleReadSucceeded else {
                throw AXEvidenceError.attributeReadFailed("AXSubrole")
            }
            if let subrole = node.subrole,
               predicate.forbiddenDescendantSubroles.contains(subrole) {
                return false
            }
            guard node.childrenReadSucceeded,
                  node.childCount == node.children.count else {
                throw AXEvidenceError.incompleteTraversal
            }
            try budget.reserve(node.children.count)
            queue.append(contentsOf: node.children)
        }
        guard window.subtreeIsComplete else {
            throw AXEvidenceError.incompleteTraversal
        }
        return true
    }

    private static func approximatelyEqual(
        _ lhs: RectValue,
        _ rhs: RectValue,
        tolerance: Double
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

public enum AXRegistrationStabilityPolicy {
    public static func isStable(
        captured: RectValue,
        current: RectValue?,
        tolerance: Double = 2
    ) -> Bool {
        guard let current,
              tolerance.isFinite,
              tolerance >= 0 else { return false }
        return abs(captured.x - current.x) <= tolerance
            && abs(captured.y - current.y) <= tolerance
            && abs(captured.width - current.width) <= tolerance
            && abs(captured.height - current.height) <= tolerance
    }
}

public enum AXGateValidator {
    @discardableResult
    public static func validate(
        discriminator: PetDiscriminator,
        axDocument: AXSnapshotDocument?,
        visibleWindows: [WindowSnapshot],
        screens: [DisplayGeometry]
    ) throws -> Bool {
        guard discriminator.requiresAX else { return false }
        guard let requirement = discriminator.axRequirement else {
            throw AXEvidenceError.missingRequirement
        }
        guard requirement.predicate == .rebornObserved else {
            throw AXEvidenceError.predicateMismatch
        }
        guard let axDocument else {
            throw AXEvidenceError.missingDocument
        }
        let selection = try AXEvidenceValidator.selectUniqueWindow(
            in: axDocument,
            predicate: requirement.predicate
        )
        let evidence = requirement.evidence
        guard discriminator.layer == 3,
              evidence.observedLayer == discriminator.layer,
              evidence.observedPID == selection.pid,
              evidence.coordinateSpace == selection.coordinateSpace,
              approximatelyEqual(
                evidence.observedBounds,
                selection.bounds,
                tolerance: 0.001
              ),
              Set(evidence.successfulNotifications)
                == Set(requirement.predicate.requiredWindowNotifications) else {
            throw AXEvidenceError.evidenceMismatch
        }
        let correlated = try AXEvidenceValidator.correlate(
            selection: selection,
            with: visibleWindows,
            expectedLayer: discriminator.layer,
            screens: screens
        )
        guard approximatelyEqual(
            correlated.bounds,
            discriminator.evidence.visibleCandidateBounds,
            tolerance: 0.001
        ) else {
            throw AXEvidenceError.evidenceMismatch
        }
        return true
    }

    private static func approximatelyEqual(
        _ lhs: RectValue,
        _ rhs: RectValue,
        tolerance: Double
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
