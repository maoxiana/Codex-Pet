import Foundation

public struct LocatorPollCoordinator: Equatable, Sendable {
    public private(set) var isRunning = false
    private var pollInProgress = false
    private var immediateScheduled = false
    private var pendingInvalidation = false

    public init() {}

    public var hasPendingWork: Bool {
        pollInProgress || immediateScheduled || pendingInvalidation
    }

    public mutating func start() {
        isRunning = true
    }

    public mutating func stop() {
        isRunning = false
        pollInProgress = false
        immediateScheduled = false
        pendingInvalidation = false
    }

    /// Returns true only when the adapter must enqueue one immediate callback.
    public mutating func receiveInvalidation() -> Bool {
        guard isRunning else { return false }
        pendingInvalidation = true
        guard !pollInProgress, !immediateScheduled else { return false }
        immediateScheduled = true
        return true
    }

    public mutating func beginImmediatePoll() -> Bool {
        guard isRunning, immediateScheduled, !pollInProgress else { return false }
        immediateScheduled = false
        pendingInvalidation = false
        pollInProgress = true
        return true
    }

    public mutating func beginTimerPoll() -> Bool {
        guard isRunning else { return false }
        guard !immediateScheduled else { return false }
        guard !pollInProgress else {
            pendingInvalidation = true
            return false
        }
        pollInProgress = true
        return true
    }

    /// Returns true only when one coalesced follow-up must be enqueued.
    public mutating func finishPoll() -> Bool {
        guard isRunning, pollInProgress else { return false }
        pollInProgress = false
        guard pendingInvalidation, !immediateScheduled else { return false }
        immediateScheduled = true
        return true
    }
}

public struct LocatorPollingCadence: Equatable, Sendable {
    private var lastMovementAt: TimeInterval?

    public init() {}

    public mutating func interval(
        notificationsActive _: Bool,
        boundsChanged: Bool,
        now: TimeInterval
    ) -> TimeInterval {
        // AX registration success does not guarantee that every animated pet move
        // produces a timely notification. Keep the adaptive verification cadence
        // active so a missed event can lag by at most one 10 Hz idle interval.
        if boundsChanged { lastMovementAt = now }
        if let lastMovementAt, now - lastMovementAt < 0.300 {
            return 1.0 / 60.0
        }
        return 0.100
    }

    public mutating func reset() {
        lastMovementAt = nil
    }
}
