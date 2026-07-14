import Foundation

public enum QuotaUnavailableReason: Equatable, Sendable {
    case transportError
    case staleSnapshot
}

public enum QuotaDisplayState: Equatable, Sendable {
    case loading
    case available(WeeklyQuota, lastUpdatedAt: Date)
    case refreshing(lastKnown: WeeklyQuota?, since: Date)
    case noWeeklyWindow
    case unavailable(QuotaUnavailableReason)
}

public enum RefreshReason: Equatable, Sendable {
    case initial
    case notification
    case manual
    case reconnection
    case scheduled
}

public struct ReadToken: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let generation: UInt64

    public init(connectionEpoch: UInt64, generation: UInt64) {
        self.connectionEpoch = connectionEpoch
        self.generation = generation
    }
}

public protocol QuotaClock: Sendable {
    var wallNow: Date { get }
    var monotonicNow: TimeInterval { get }
}

public struct SystemQuotaClock: QuotaClock {
    public init() {}

    public var wallNow: Date {
        Date()
    }

    public var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

public struct FixedQuotaClock: QuotaClock {
    public let wallNow: Date
    public let monotonicNow: TimeInterval

    public init(now: Date, monotonicNow: TimeInterval = 0) {
        wallNow = now
        self.monotonicNow = monotonicNow
    }

    public init(wallNow: Date, monotonicNow: TimeInterval) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
    }
}

public extension QuotaClock {
    var now: Date {
        wallNow
    }
}

public actor QuotaRefreshMachine {
    private static let staleGraceDuration: TimeInterval = 30
    private static let maximumImmediateExpiredRefreshes = 3

    private let clock: any QuotaClock
    private let stateBroadcaster: QuotaStateBroadcaster

    private var displayState: QuotaDisplayState
    private var connectionEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var inFlight: ReadToken?
    private var dirty = false
    private var lastFreshQuota: WeeklyQuota?
    private var expiredFingerprints: Set<String> = []
    private var expiredImmediateRefreshCount = 0
    private var staleSince: Date?
    private var staleStartedAtMonotonic: TimeInterval?
    private var staleLockedOut = false

    public init(clock: any QuotaClock = SystemQuotaClock()) {
        self.clock = clock
        let initialState = QuotaDisplayState.loading
        displayState = initialState
        stateBroadcaster = QuotaStateBroadcaster(initialState: initialState)
    }

    /// Each access creates an independent current-state subscription. The
    /// current value is replayed and only the newest pending transition is
    /// buffered, so intermediate transitions may coalesce for slow consumers.
    public nonisolated var states: AsyncStream<QuotaDisplayState> {
        subscribeStates()
    }

    /// Creates an independent stream that immediately replays the current state.
    /// It buffers the newest pending state only; slow consumers may not observe
    /// every intermediate transition.
    public nonisolated func subscribeStates() -> AsyncStream<QuotaDisplayState> {
        stateBroadcaster.subscribe()
    }

    nonisolated var subscriberCountForTesting: Int {
        stateBroadcaster.subscriberCount
    }

    public var currentState: QuotaDisplayState {
        displayState
    }

    var expiredFingerprintCountForTesting: Int {
        expiredFingerprints.count
    }

    var expiredImmediateRefreshCountForTesting: Int {
        expiredImmediateRefreshCount
    }

    @discardableResult
    public func connectionStarted() -> UInt64 {
        connectionEpoch &+= 1
        inFlight = nil
        dirty = false
        return connectionEpoch
    }

    public func invalidate(_ reason: RefreshReason) -> ReadToken? {
        _ = reason
        guard inFlight == nil else {
            dirty = true
            return nil
        }

        if staleSince == nil, let lastFreshQuota {
            publish(.refreshing(lastKnown: lastFreshQuota, since: clock.wallNow))
        }
        return beginRead()
    }

    public func complete(
        _ token: ReadToken,
        result: Result<WeeklyQuotaExtraction, Error>
    ) -> ReadToken? {
        guard token.connectionEpoch == connectionEpoch, token == inFlight else {
            return nil
        }
        inFlight = nil

        if dirty {
            dirty = false
            if staleLockedOut,
               case .success(let extraction) = result,
               let quota = extraction.quota,
               let resetsAt = quota.resetsAt,
               resetsAt <= clock.wallNow {
                return nil
            }
            return beginRead()
        }

        switch result {
        case .failure:
            publish(.unavailable(.transportError))
            return nil

        case .success(let extraction):
            guard let quota = extraction.quota else {
                lastFreshQuota = nil
                resetStaleEpisode()
                publish(.noWeeklyWindow)
                return nil
            }

            let observedAt = clock.wallNow
            guard let resetsAt = quota.resetsAt, resetsAt <= observedAt else {
                lastFreshQuota = quota
                resetStaleEpisode()
                publish(.available(quota, lastUpdatedAt: observedAt))
                return nil
            }

            return handleExpired(quota, observedAt: observedAt)
        }
    }

    public func tick() -> ReadToken? {
        guard !staleLockedOut,
              let staleStartedAtMonotonic,
              clock.monotonicNow - staleStartedAtMonotonic >= Self.staleGraceDuration else {
            return nil
        }
        staleLockedOut = true
        publish(.unavailable(.staleSnapshot))
        return nil
    }

    /// Deprecated source-compatibility shim. The Date argument is ignored;
    /// grace timing is exclusively monotonic through `tick()`.
    @available(
        *,
        deprecated,
        message: "Wall-clock input is ignored; use tick() for monotonic stale-grace timing."
    )
    public func tick(now: Date) -> ReadToken? {
        _ = now
        return tick()
    }

    private func handleExpired(_ quota: WeeklyQuota, observedAt: Date) -> ReadToken? {
        guard !staleLockedOut else {
            return nil
        }

        if staleSince == nil {
            staleSince = observedAt
            staleStartedAtMonotonic = clock.monotonicNow
        }

        publish(.refreshing(lastKnown: lastFreshQuota, since: staleSince ?? observedAt))

        guard expiredImmediateRefreshCount < Self.maximumImmediateExpiredRefreshes,
              !expiredFingerprints.contains(quota.fingerprint) else {
            return nil
        }
        expiredFingerprints.insert(quota.fingerprint)
        expiredImmediateRefreshCount += 1
        return beginRead()
    }

    private func resetStaleEpisode() {
        staleSince = nil
        staleStartedAtMonotonic = nil
        staleLockedOut = false
        expiredFingerprints = []
        expiredImmediateRefreshCount = 0
    }

    private func beginRead() -> ReadToken {
        generation &+= 1
        let token = ReadToken(connectionEpoch: connectionEpoch, generation: generation)
        inFlight = token
        return token
    }

    private func publish(_ state: QuotaDisplayState) {
        guard displayState != state else {
            return
        }
        displayState = state
        stateBroadcaster.publish(state)
    }
}

private final class QuotaStateBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var currentState: QuotaDisplayState
    private var continuations: [UUID: AsyncStream<QuotaDisplayState>.Continuation] = [:]

    init(initialState: QuotaDisplayState) {
        currentState = initialState
    }

    func subscribe() -> AsyncStream<QuotaDisplayState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }

            lock.lock()
            continuations[id] = continuation
            continuation.yield(currentState)
            lock.unlock()
        }
    }

    func publish(_ state: QuotaDisplayState) {
        lock.lock()
        currentState = state
        let subscribers = Array(continuations.values)
        lock.unlock()

        for continuation in subscribers {
            continuation.yield(state)
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    deinit {
        lock.lock()
        let subscribers = Array(continuations.values)
        continuations = [:]
        lock.unlock()

        for continuation in subscribers {
            continuation.finish()
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
