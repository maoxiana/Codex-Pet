import Foundation

public enum AppLifecyclePhase: Equatable, Sendable {
    case notStarted
    case waitingForHost
    case hostRunning
    case stopped
}

public enum AppLifecycleEffect: Equatable, Sendable {
    case installHostMonitors
    case removeHostMonitors
    case startAppServer
    case stopAppServerAndReapChild
    case startPetLocator
    case stopPetLocator
    case hidePanel
}

/// Pure lifecycle reducer. AppKit owns the concrete resources; this state
/// machine makes the ordering and idempotency of their lifetime explicit.
public struct AppLifecycleState: Equatable, Sendable {
    public private(set) var phase: AppLifecyclePhase = .notStarted
    public private(set) var appServerIsRunning = false
    public private(set) var petLocatorIsRunning = false
    private var monitorsAreInstalled = false

    public init() {}

    public mutating func bootstrap(hostIsRunning: Bool) -> [AppLifecycleEffect] {
        guard phase == .notStarted else { return [] }
        monitorsAreInstalled = true
        if hostIsRunning {
            phase = .hostRunning
            appServerIsRunning = true
            petLocatorIsRunning = true
            return [.installHostMonitors, .startAppServer, .startPetLocator]
        }
        phase = .waitingForHost
        return [.installHostMonitors]
    }

    public mutating func hostLaunched() -> [AppLifecycleEffect] {
        guard phase == .waitingForHost else { return [] }
        phase = .hostRunning
        appServerIsRunning = true
        petLocatorIsRunning = true
        return [.startAppServer, .startPetLocator]
    }

    public mutating func hostTerminated() -> [AppLifecycleEffect] {
        guard phase == .hostRunning else { return [] }
        phase = .waitingForHost
        appServerIsRunning = false
        petLocatorIsRunning = false
        return [.stopAppServerAndReapChild, .stopPetLocator, .hidePanel]
    }

    public mutating func shutdown() -> [AppLifecycleEffect] {
        guard phase != .stopped else { return [] }
        var effects: [AppLifecycleEffect] = []
        if appServerIsRunning { effects.append(.stopAppServerAndReapChild) }
        if petLocatorIsRunning { effects.append(.stopPetLocator) }
        effects.append(.hidePanel)
        if monitorsAreInstalled { effects.append(.removeHostMonitors) }
        appServerIsRunning = false
        petLocatorIsRunning = false
        monitorsAreInstalled = false
        phase = .stopped
        return effects
    }
}

public enum SingleInstanceDecision: Equatable, Sendable {
    case continueLaunching
    case exitSuccessfully
}

public enum SingleInstancePolicy {
    public static func decision(lockAcquired: Bool) -> SingleInstanceDecision {
        lockAcquired ? .continueLaunching : .exitSuccessfully
    }
}

public enum AppServerLifecycleEffect: Equatable, Sendable {
    case start(generation: UInt64)
    case cancelAndReap(generation: UInt64)
}

/// Serializes ownership of the App Server child. A new generation cannot be
/// started while the prior generation is still being reaped.
public struct AppServerLifecycleCoordinator: Equatable, Sendable {
    public private(set) var activeGeneration: UInt64?
    public private(set) var reapingGeneration: UInt64?
    private var nextGeneration: UInt64 = 1

    public init() {}

    public mutating func requestStart(
        hostPresent: Bool,
        permissionReady: Bool,
        blocked: Bool
    ) -> [AppServerLifecycleEffect] {
        guard hostPresent, permissionReady, !blocked,
              activeGeneration == nil, reapingGeneration == nil else { return [] }
        let generation = nextGeneration
        nextGeneration &+= 1
        activeGeneration = generation
        return [.start(generation: generation)]
    }

    public mutating func requestStop() -> [AppServerLifecycleEffect] {
        guard reapingGeneration == nil, let generation = activeGeneration else { return [] }
        activeGeneration = nil
        reapingGeneration = generation
        return [.cancelAndReap(generation: generation)]
    }

    @discardableResult
    public mutating func runEnded(generation: UInt64) -> Bool {
        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        return true
    }

    public mutating func reapCompleted(
        generation: UInt64,
        hostPresent: Bool,
        permissionReady: Bool,
        blocked: Bool
    ) -> [AppServerLifecycleEffect] {
        guard reapingGeneration == generation else { return [] }
        reapingGeneration = nil
        return requestStart(
            hostPresent: hostPresent,
            permissionReady: permissionReady,
            blocked: blocked
        )
    }
}
