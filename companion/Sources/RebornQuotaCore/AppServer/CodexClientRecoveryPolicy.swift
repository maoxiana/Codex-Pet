import Foundation

public enum CodexClientRecoveryAction: Equatable, Sendable {
    case stop
    case retryAfterBackoff
    case retryAuthenticationAfter(seconds: TimeInterval)
    case waitForHostOrExecutableIdentityChange
}

public enum CodexClientRecoveryPolicy {
    public static func action(
        for error: CodexRateLimitClientError
    ) -> CodexClientRecoveryAction {
        switch error {
        case .cancelled:
            return .stop
        case .authenticationRequired:
            return .retryAuthenticationAfter(seconds: 60)
        case .alreadyRunning, .executableChanged, .incompatibleProtocol:
            return .waitForHostOrExecutableIdentityChange
        case .responseError, .timeout, .transportFailure, .transport:
            return .retryAfterBackoff
        }
    }
}

public enum RecoveryRetryEffect: Equatable, Sendable {
    case schedule(token: UInt64, after: TimeInterval)
    case cancel(token: UInt64)
}

/// Owns the logical retry timer independently from the runtime task. This
/// prevents duplicate retry loops and makes stale timer callbacks harmless.
public struct RecoveryRetryCoordinator: Equatable, Sendable {
    public private(set) var scheduledToken: UInt64?
    private var nextToken: UInt64 = 1

    public init() {}

    public mutating func schedule(after delay: TimeInterval) -> [RecoveryRetryEffect] {
        guard scheduledToken == nil else { return [] }
        let token = nextToken
        nextToken &+= 1
        scheduledToken = token
        return [.schedule(token: token, after: delay)]
    }

    public mutating func cancel() -> [RecoveryRetryEffect] {
        guard let token = scheduledToken else { return [] }
        scheduledToken = nil
        return [.cancel(token: token)]
    }

    public mutating func timerFired(
        token: UInt64,
        runtimeEligible: Bool
    ) -> Bool {
        guard scheduledToken == token else { return false }
        scheduledToken = nil
        return runtimeEligible
    }
}
