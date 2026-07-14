import Foundation

public enum TerminationCoordinatorPhase: Equatable, Sendable {
    case running
    case shuttingDown
    case finished
}

public enum TerminationCoordinatorEffect: Equatable, Sendable {
    case beginLifecycleShutdown
    case scheduleForcedCompletion(after: TimeInterval)
    case markCleanExit
    case exitSuccessfully
    case exitFailure
}

public struct TerminationCoordinatorState: Equatable, Sendable {
    public static let recommendedSignalTimeoutSeconds: TimeInterval = 4

    public private(set) var phase: TerminationCoordinatorPhase = .running
    private let timeoutSeconds: TimeInterval

    public init(
        timeoutSeconds: TimeInterval = Self.recommendedSignalTimeoutSeconds
    ) {
        self.timeoutSeconds = timeoutSeconds
    }

    public mutating func receiveSignal() -> [TerminationCoordinatorEffect] {
        guard phase == .running else { return [] }
        phase = .shuttingDown
        return [
            .beginLifecycleShutdown,
            .scheduleForcedCompletion(after: timeoutSeconds),
        ]
    }

    public mutating func shutdownFinished() -> [TerminationCoordinatorEffect] {
        guard phase == .shuttingDown else { return [] }
        phase = .finished
        return [.markCleanExit, .exitSuccessfully]
    }

    public mutating func shutdownTimedOut() -> [TerminationCoordinatorEffect] {
        guard phase == .shuttingDown else { return [] }
        phase = .finished
        return [.exitFailure]
    }
}
