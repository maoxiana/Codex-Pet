import Foundation

public struct PermissionPersistence: Codable, Equatable, Sendable {
    public var rationaleShown: Bool
    public var systemPromptAttempted: Bool
    public var denialRecorded: Bool
    public var recoveryAffordanceShown: Bool
    public var recoveryIdentity: String?

    public static let empty = Self(
        rationaleShown: false,
        systemPromptAttempted: false,
        denialRecorded: false,
        recoveryAffordanceShown: false,
        recoveryIdentity: nil
    )

    public init(
        rationaleShown: Bool,
        systemPromptAttempted: Bool,
        denialRecorded: Bool,
        recoveryAffordanceShown: Bool = false,
        recoveryIdentity: String? = nil
    ) {
        self.rationaleShown = rationaleShown
        self.systemPromptAttempted = systemPromptAttempted
        self.denialRecorded = denialRecorded
        self.recoveryAffordanceShown = recoveryAffordanceShown
        self.recoveryIdentity = recoveryIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case rationaleShown
        case systemPromptAttempted
        case denialRecorded
        case recoveryAffordanceShown
        case recoveryIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rationaleShown = try container.decode(Bool.self, forKey: .rationaleShown)
        systemPromptAttempted = try container.decode(Bool.self, forKey: .systemPromptAttempted)
        denialRecorded = try container.decode(Bool.self, forKey: .denialRecorded)
        recoveryAffordanceShown = try container.decodeIfPresent(
            Bool.self,
            forKey: .recoveryAffordanceShown
        ) ?? false
        recoveryIdentity = try container.decodeIfPresent(String.self, forKey: .recoveryIdentity)
    }
}

public enum PermissionState: Equatable, Sendable {
    case notRequired
    case needsRationale
    case awaitingSystemPrompt
    case denied
    case authorized
}

public enum PermissionEffect: Equatable, Sendable {
    case showRationale
    case requestSystemPrompt
    case persist(PermissionPersistence)
    case hideForDegradedMode
    case scheduleTrustRecheck(after: TimeInterval)
    case permissionReady
    case openAccessibilitySettings
    case showRecoveryAffordance
}

/// Pure reducer for the one-time Accessibility permission flow. A system
/// prompt is never emitted after `systemPromptAttempted` has been persisted.
public struct PermissionStateMachine: Sendable {
    public static let recheckInterval: TimeInterval = 30
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    public private(set) var state: PermissionState
    public private(set) var persistence: PermissionPersistence
    public private(set) var effectsSoFar: [PermissionEffect] = []

    private let requiresAX: Bool
    private var trusted: Bool
    private var currentTime: Date
    private var nextRecheckAt: Date?

    public init(
        requiresAX: Bool,
        persistence: PermissionPersistence,
        trusted: Bool,
        now: Date,
        currentIdentity: String = ""
    ) {
        self.requiresAX = requiresAX
        var normalizedPersistence = persistence
        if !currentIdentity.isEmpty,
           normalizedPersistence.recoveryIdentity != currentIdentity {
            normalizedPersistence.recoveryIdentity = currentIdentity
            normalizedPersistence.recoveryAffordanceShown = false
            if normalizedPersistence.systemPromptAttempted, !trusted {
                normalizedPersistence.denialRecorded = true
            }
        }
        self.persistence = normalizedPersistence
        self.trusted = trusted
        currentTime = now
        if !requiresAX {
            state = .notRequired
        } else if trusted {
            state = .authorized
        } else if !persistence.rationaleShown {
            state = .needsRationale
        } else if !persistence.systemPromptAttempted {
            state = .awaitingSystemPrompt
        } else {
            state = .denied
        }
    }

    public mutating func bootstrap() -> [PermissionEffect] {
        let effects: [PermissionEffect]
        if !requiresAX {
            effects = [.permissionReady]
        } else if trusted {
            if persistence.denialRecorded {
                persistence.denialRecorded = false
                effects = [.persist(persistence), .permissionReady]
            } else {
                effects = [.permissionReady]
            }
        } else if !persistence.rationaleShown {
            state = .needsRationale
            effects = [.showRationale]
        } else if !persistence.systemPromptAttempted {
            state = .awaitingSystemPrompt
            persistence.systemPromptAttempted = true
            effects = [.persist(persistence), .requestSystemPrompt]
        } else {
            state = .denied
            nextRecheckAt = currentTime.addingTimeInterval(Self.recheckInterval)
            effects = degradedEffectsWithRecovery()
        }
        return record(effects)
    }

    public mutating func rationaleAccepted() -> [PermissionEffect] {
        guard requiresAX, state == .needsRationale else { return [] }
        persistence.rationaleShown = true
        persistence.systemPromptAttempted = true
        state = .awaitingSystemPrompt
        return record([.persist(persistence), .requestSystemPrompt])
    }

    public mutating func rationaleDeclined(now: Date) -> [PermissionEffect] {
        guard requiresAX, state == .needsRationale else { return [] }
        currentTime = now
        persistence.rationaleShown = true
        // Persist the user's explicit deferral as a completed attempt so a
        // future launch cannot surprise them with a system prompt.
        persistence.systemPromptAttempted = true
        persistence.denialRecorded = true
        persistence.recoveryAffordanceShown = true
        state = .denied
        nextRecheckAt = now.addingTimeInterval(Self.recheckInterval)
        return record([.persist(persistence)] + degradedEffects())
    }

    public mutating func systemPromptCompleted(
        trusted: Bool,
        now: Date
    ) -> [PermissionEffect] {
        currentTime = now
        self.trusted = trusted
        guard requiresAX else { return [] }
        if trusted {
            state = .authorized
            nextRecheckAt = nil
            persistence.denialRecorded = false
            return record([.persist(persistence), .permissionReady])
        }
        state = .denied
        persistence.denialRecorded = true
        nextRecheckAt = now.addingTimeInterval(Self.recheckInterval)
        return record([.persist(persistence)] + degradedEffects())
    }

    public mutating func recheck(trusted: Bool, now: Date) -> [PermissionEffect] {
        guard requiresAX, state == .denied,
              let nextRecheckAt, now >= nextRecheckAt else { return [] }
        currentTime = now
        self.trusted = trusted
        if trusted {
            state = .authorized
            self.nextRecheckAt = nil
            persistence.denialRecorded = false
            return record([.persist(persistence), .permissionReady])
        }
        self.nextRecheckAt = now.addingTimeInterval(Self.recheckInterval)
        return record(degradedEffectsWithRecovery())
    }

    public mutating func openSettings() -> [PermissionEffect] {
        record([.openAccessibilitySettings])
    }

    private func degradedEffects() -> [PermissionEffect] {
        [.hideForDegradedMode, .scheduleTrustRecheck(after: Self.recheckInterval)]
    }

    private mutating func degradedEffectsWithRecovery() -> [PermissionEffect] {
        var effects: [PermissionEffect] = [.hideForDegradedMode]
        if !persistence.recoveryAffordanceShown {
            persistence.recoveryAffordanceShown = true
            effects.append(.persist(persistence))
            effects.append(.showRecoveryAffordance)
        }
        effects.append(.scheduleTrustRecheck(after: Self.recheckInterval))
        return effects
    }

    private mutating func record(_ effects: [PermissionEffect]) -> [PermissionEffect] {
        effectsSoFar.append(contentsOf: effects)
        return effects
    }
}
