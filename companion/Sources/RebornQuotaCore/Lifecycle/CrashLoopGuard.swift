import Foundation

public struct CrashLoopState: Codable, Equatable, Sendable {
    public var recentFailureDates: [Date]
    public var activeLaunchStartedAt: Date?

    public static let empty = Self(recentFailureDates: [], activeLaunchStartedAt: nil)

    public init(recentFailureDates: [Date], activeLaunchStartedAt: Date?) {
        self.recentFailureDates = recentFailureDates
        self.activeLaunchStartedAt = activeLaunchStartedAt
    }
}

public protocol CrashLoopStorage: Sendable {
    func load() throws -> CrashLoopState?
    func save(_ state: CrashLoopState) throws
}

public protocol CrashLoopClock: Sendable {
    var now: Date { get }
}

public struct SystemCrashLoopClock: CrashLoopClock {
    public init() {}
    public var now: Date { Date() }
}

public enum CrashLoopLaunchDecision: Equatable, Sendable {
    case continueLaunching
    case exitSuccessfully
}

public struct CrashLoopGuard: Sendable {
    public static let rapidFailureWindow: TimeInterval = 5 * 60
    public static let healthyResetInterval: TimeInterval = 10 * 60
    public static let maximumRapidFailures = 3

    private let storage: any CrashLoopStorage
    private let clock: any CrashLoopClock

    public init(storage: any CrashLoopStorage, clock: any CrashLoopClock = SystemCrashLoopClock()) {
        self.storage = storage
        self.clock = clock
    }

    /// A persisted active marker means the preceding process did not survive
    /// long enough to mark itself healthy. The next launch records that as one
    /// rapid failure. Returning success lets launchd's KeepAlive policy stop.
    public mutating func beginLaunch() throws -> CrashLoopLaunchDecision {
        let now = clock.now
        var state = try storage.load() ?? .empty
        state.recentFailureDates.removeAll {
            now.timeIntervalSince($0) > Self.rapidFailureWindow
        }
        if state.activeLaunchStartedAt != nil {
            state.recentFailureDates.append(now)
        }
        guard state.recentFailureDates.count < Self.maximumRapidFailures else {
            state.activeLaunchStartedAt = nil
            try storage.save(state)
            return .exitSuccessfully
        }
        state.activeLaunchStartedAt = now
        try storage.save(state)
        return .continueLaunching
    }

    @discardableResult
    public mutating func markHealthyIfEligible() throws -> Bool {
        var state = try storage.load() ?? .empty
        guard let startedAt = state.activeLaunchStartedAt,
              clock.now.timeIntervalSince(startedAt) >= Self.healthyResetInterval else {
            return false
        }
        state = .empty
        try storage.save(state)
        return true
    }

    public mutating func markCleanExit() throws {
        var state = try storage.load() ?? .empty
        state.activeLaunchStartedAt = nil
        try storage.save(state)
    }
}

public struct JSONFileCrashLoopStorage: CrashLoopStorage, @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> CrashLoopState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Runtime state is advisory. A truncated write must not permanently
        // disable the LaunchAgent; treat undecodable state as a fresh guard.
        return try? JSONDecoder().decode(CrashLoopState.self, from: data)
    }

    public func save(_ state: CrashLoopState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
