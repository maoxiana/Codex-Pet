import Foundation
import XCTest
@testable import RebornQuotaCore

final class QuotaRefreshMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testOnlyOneReadIsInFlight() async {
        let machine = makeMachine()
        _ = await machine.connectionStarted()

        let first = await machine.invalidate(.initial)
        let overlapping = await machine.invalidate(.notification)

        XCTAssertNotNil(first)
        assertNil(overlapping)
    }

    func testNotificationsDuringReadCoalesceIntoOneFollowUp() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))

        assertNil(await machine.invalidate(.notification))
        assertNil(await machine.invalidate(.notification))
        assertNil(await machine.invalidate(.notification))

        let followUp = try unwrap(
            await machine.complete(first, result: .success(extraction(quota: freshQuota())))
        )
        XCTAssertNotEqual(followUp, first)

        let noThirdRead = await machine.complete(
            followUp,
            result: .success(extraction(quota: freshQuota(remainingPercent: 63)))
        )
        assertNil(noThirdRead)
    }

    func testResponseFromOldConnectionEpochIsDiscarded() async throws {
        let machine = makeMachine()
        let stream = machine.subscribeStates()
        var states = stream.makeAsyncIterator()
        _ = await states.next()

        let firstEpoch = await machine.connectionStarted()
        let oldToken = try unwrap(await machine.invalidate(.initial))
        let secondEpoch = await machine.connectionStarted()
        let currentToken = try unwrap(await machine.invalidate(.initial))

        XCTAssertGreaterThan(secondEpoch, firstEpoch)
        assertNil(
            await machine.complete(
                oldToken,
                result: .success(extraction(quota: freshQuota(remainingPercent: 1)))
            )
        )
        assertNil(
            await machine.complete(
                currentToken,
                result: .success(extraction(quota: freshQuota(remainingPercent: 81)))
            )
        )

        let published = await states.next()
        assertEqual(published, .available(freshQuota(remainingPercent: 81), lastUpdatedAt: now))
    }

    func testDirtyResponseDoesNotPublishBeforeFollowUp() async throws {
        let machine = makeMachine()
        let stream = machine.subscribeStates()
        var states = stream.makeAsyncIterator()
        assertEqual(await states.next(), .loading)

        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))
        assertNil(await machine.invalidate(.notification))

        let followUp = try unwrap(
            await machine.complete(first, result: .success(extraction(quota: freshQuota())))
        )
        let stateBeforeFollowUp = await machine.currentState
        assertEqual(stateBeforeFollowUp, .loading)

        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: freshQuota(remainingPercent: 44)))
            )
        )
        assertEqual(
            await states.next(),
            .available(freshQuota(remainingPercent: 44), lastUpdatedAt: now)
        )
    }

    func testInitialExpiredSnapshotStartsRefreshingWithoutLastKnownData() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let token = try unwrap(await machine.invalidate(.initial))
        let expired = expiredQuota(fingerprint: "expired-a")

        let followUp = await machine.complete(token, result: .success(extraction(quota: expired)))

        XCTAssertNotNil(followUp)
        assertEqual(
            await machine.currentState,
            .refreshing(lastKnown: nil, since: now)
        )
    }

    func testSameExpiredFingerprintTriggersOnlyOneImmediateRefresh() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))
        let expired = expiredQuota(fingerprint: "expired-a")

        let followUp = try unwrap(
            await machine.complete(first, result: .success(extraction(quota: expired)))
        )
        let loop = await machine.complete(
            followUp,
            result: .success(extraction(quota: expired))
        )

        assertNil(loop)
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))
    }

    func testRepeatedExpiredSnapshotsDoNotAdvanceGraceDeadline() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))
        let firstExpired = expiredQuota(fingerprint: "expired-a")
        let followUp = try unwrap(
            await machine.complete(first, result: .success(extraction(quota: firstExpired)))
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: firstExpired))
            )
        )

        let laterRead = try unwrap(await machine.invalidate(.notification))
        let differentExpired = expiredQuota(fingerprint: "expired-b")
        let differentFollowUp = try unwrap(
            await machine.complete(
                laterRead,
                result: .success(extraction(quota: differentExpired))
            )
        )

        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))
        assertNil(
            await machine.complete(
                differentFollowUp,
                result: .success(extraction(quota: differentExpired))
            )
        )
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))
    }

    func testGraceExpiryBecomesUnavailableStaleSnapshot() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 100)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))
        let followUp = try unwrap(
            await machine.complete(
                first,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )

        clock.setMonotonicNow(129.999)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))
        clock.setMonotonicNow(130)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
    }

    func testManyUniqueExpiredFingerprintsUseBoundedImmediateRetryBudget() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        var token = try unwrap(await machine.invalidate(.initial))

        for index in 0..<20 {
            let followUp = await machine.complete(
                token,
                result: .success(
                    extraction(quota: expiredQuota(fingerprint: "expired-\(index)"))
                )
            )

            if index < 3 {
                token = try unwrap(followUp)
            } else {
                assertNil(followUp)
                if index < 19 {
                    token = try unwrap(await machine.invalidate(.notification))
                }
            }
        }

        assertEqual(await machine.expiredFingerprintCountForTesting, 3)
        assertEqual(await machine.expiredImmediateRefreshCountForTesting, 3)
    }

    func testExpiredCompletionAfterStaleDeadlineCannotRestartOrAutoRead() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let inFlightAtDeadline = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )

        clock.setMonotonicNow(30)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))

        assertNil(
            await machine.complete(
                inFlightAtDeadline,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-b")))
            )
        )
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))

        let explicitRead = try unwrap(await machine.invalidate(.manual))
        assertNil(
            await machine.complete(
                explicitRead,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-c")))
            )
        )
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
    }

    func testDirtyExpiredCompletionAfterStaleDeadlineDoesNotStartFollowUp() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let inFlightAtDeadline = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(await machine.invalidate(.notification))

        clock.setMonotonicNow(30)
        _ = await machine.tick()
        let followUp = await machine.complete(
            inFlightAtDeadline,
            result: .success(extraction(quota: expiredQuota(fingerprint: "expired-b")))
        )

        assertNil(followUp)
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
    }

    func testReconnectBeforeDeadlinePreservesOriginalMonotonicGraceDeadline() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let followUp = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )

        clock.setMonotonicNow(20)
        _ = await machine.connectionStarted()
        clock.setMonotonicNow(29.999)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))

        clock.setMonotonicNow(30)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
    }

    func testRepeatedReconnectsDoNotExtendStaleGraceDeadline() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let followUp = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )

        for reconnectAt in [5.0, 10.0, 20.0, 29.999] {
            clock.setMonotonicNow(reconnectAt)
            _ = await machine.connectionStarted()
        }
        clock.setMonotonicNow(30)
        assertNil(await machine.tick())

        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
        assertEqual(await machine.expiredFingerprintCountForTesting, 1)
        assertEqual(await machine.expiredImmediateRefreshCountForTesting, 1)
    }

    func testReconnectAfterStaleLockoutDoesNotRearmExpiredRetry() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let followUp = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        clock.setMonotonicNow(30)
        _ = await machine.tick()

        _ = await machine.connectionStarted()
        let reconnectedRead = try unwrap(await machine.invalidate(.reconnection))
        let retry = await machine.complete(
            reconnectedRead,
            result: .success(extraction(quota: expiredQuota(fingerprint: "expired-b")))
        )

        assertNil(retry)
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
        assertEqual(await machine.expiredFingerprintCountForTesting, 1)
        assertEqual(await machine.expiredImmediateRefreshCountForTesting, 1)
    }

    func testFreshResultResetsExpiredRetryBudget() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        var token = try unwrap(await machine.invalidate(.initial))

        for index in 0..<3 {
            token = try unwrap(
                await machine.complete(
                    token,
                    result: .success(
                        extraction(quota: expiredQuota(fingerprint: "expired-\(index)"))
                    )
                )
            )
        }
        assertNil(
            await machine.complete(
                token,
                result: .success(extraction(quota: expiredQuota(fingerprint: "exhausted")))
            )
        )

        let freshRead = try unwrap(await machine.invalidate(.manual))
        assertNil(
            await machine.complete(
                freshRead,
                result: .success(extraction(quota: freshQuota()))
            )
        )
        let nextEpisode = try unwrap(await machine.invalidate(.notification))
        let nextFollowUp = await machine.complete(
            nextEpisode,
            result: .success(extraction(quota: expiredQuota(fingerprint: "new-episode")))
        )

        XCTAssertNotNil(nextFollowUp)
        assertEqual(await machine.expiredImmediateRefreshCountForTesting, 1)
    }

    func testNoWeeklyResultResetsStaleLockout() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 0)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let inFlightAtDeadline = try unwrap(
            await machine.complete(
                initial,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        clock.setMonotonicNow(30)
        _ = await machine.tick()

        assertNil(
            await machine.complete(
                inFlightAtDeadline,
                result: .success(extraction(quota: nil))
            )
        )
        let nextEpisode = try unwrap(await machine.invalidate(.notification))
        let followUp = await machine.complete(
            nextEpisode,
            result: .success(extraction(quota: expiredQuota(fingerprint: "expired-b")))
        )

        XCTAssertNotNil(followUp)
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))
    }

    func testWallClockJumpsDoNotChangeMonotonicGraceDuration() async throws {
        let clock = ManualQuotaClock(wallNow: now, monotonicNow: 500)
        let machine = QuotaRefreshMachine(clock: clock)
        _ = await machine.connectionStarted()
        let first = try unwrap(await machine.invalidate(.initial))
        let followUp = try unwrap(
            await machine.complete(
                first,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )
        assertNil(
            await machine.complete(
                followUp,
                result: .success(extraction(quota: expiredQuota(fingerprint: "expired-a")))
            )
        )

        clock.setWallNow(now.addingTimeInterval(10 * 365 * 24 * 60 * 60))
        clock.setMonotonicNow(529.999)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .refreshing(lastKnown: nil, since: now))

        clock.setWallNow(now.addingTimeInterval(-10 * 365 * 24 * 60 * 60))
        clock.setMonotonicNow(530)
        assertNil(await machine.tick())
        assertEqual(await machine.currentState, .unavailable(.staleSnapshot))
    }

    func testFreshSnapshotUpdatesLastUpdatedAt() async throws {
        let observedAt = Date(timeIntervalSince1970: 2_100_000_000)
        let machine = QuotaRefreshMachine(clock: FixedQuotaClock(now: observedAt))
        _ = await machine.connectionStarted()
        let token = try unwrap(await machine.invalidate(.initial))
        let quota = WeeklyQuota(
            remainingPercent: 64,
            resetsAt: observedAt.addingTimeInterval(3_600),
            fingerprint: "fresh-observed-at"
        )

        assertNil(
            await machine.complete(token, result: .success(extraction(quota: quota)))
        )
        assertEqual(await machine.currentState, .available(quota, lastUpdatedAt: observedAt))
    }

    func testNoWeeklyWindowPublishesNoWeeklyWindow() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let token = try unwrap(await machine.invalidate(.initial))

        assertNil(
            await machine.complete(token, result: .success(extraction(quota: nil)))
        )
        assertEqual(await machine.currentState, .noWeeklyWindow)
    }

    func testMissingResetTimeIsFresh() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let token = try unwrap(await machine.invalidate(.initial))
        let quota = WeeklyQuota(
            remainingPercent: 72,
            resetsAt: nil,
            fingerprint: "missing-reset"
        )

        assertNil(
            await machine.complete(token, result: .success(extraction(quota: quota)))
        )
        assertEqual(await machine.currentState, .available(quota, lastUpdatedAt: now))
    }

    func testTransportErrorPublishesTypedUnavailableState() async throws {
        let machine = makeMachine()
        _ = await machine.connectionStarted()
        let token = try unwrap(await machine.invalidate(.initial))

        assertNil(await machine.complete(token, result: .failure(TestError.transport)))
        assertEqual(await machine.currentState, .unavailable(.transportError))
    }

    func testReconnectionResetsEpochAndInflightSafely() async throws {
        let machine = makeMachine()
        let oldEpoch = await machine.connectionStarted()
        let oldToken = try unwrap(await machine.invalidate(.initial))
        assertNil(await machine.invalidate(.notification))

        let newEpoch = await machine.connectionStarted()
        let newToken = try unwrap(await machine.invalidate(.initial))

        XCTAssertGreaterThan(newEpoch, oldEpoch)
        XCTAssertEqual(newToken.connectionEpoch, newEpoch)
        assertNil(
            await machine.complete(
                oldToken,
                result: .success(extraction(quota: freshQuota(remainingPercent: 2)))
            )
        )
        assertNil(
            await machine.complete(
                newToken,
                result: .success(extraction(quota: freshQuota(remainingPercent: 92)))
            )
        )
        assertEqual(
            await machine.currentState,
            .available(freshQuota(remainingPercent: 92), lastUpdatedAt: now)
        )
    }

    func testStateSubscriptionsReplayCurrentStateAndBroadcastFutureStates() async throws {
        let machine = makeMachine()
        let firstStream = machine.states
        var first = firstStream.makeAsyncIterator()
        assertEqual(await first.next(), .loading)

        _ = await machine.connectionStarted()
        let initialToken = try unwrap(await machine.invalidate(.initial))
        let quota = freshQuota(remainingPercent: 68)
        assertNil(
            await machine.complete(initialToken, result: .success(extraction(quota: quota)))
        )
        assertEqual(await first.next(), .available(quota, lastUpdatedAt: now))

        let lateStream = machine.subscribeStates()
        var late = lateStream.makeAsyncIterator()
        assertEqual(await late.next(), .available(quota, lastUpdatedAt: now))

        let refreshToken = try unwrap(await machine.invalidate(.notification))
        assertEqual(await first.next(), .refreshing(lastKnown: quota, since: now))
        assertEqual(await late.next(), .refreshing(lastKnown: quota, since: now))

        assertNil(
            await machine.complete(refreshToken, result: .success(extraction(quota: nil)))
        )
        assertEqual(await first.next(), .noWeeklyWindow)
        assertEqual(await late.next(), .noWeeklyWindow)
    }

    func testSlowSubscriberReceivesOnlyLatestBufferedState() async throws {
        let machine = makeMachine()
        let stream = machine.subscribeStates()
        var slowSubscriber = stream.makeAsyncIterator()

        _ = await machine.connectionStarted()
        let initial = try unwrap(await machine.invalidate(.initial))
        let quota = freshQuota(remainingPercent: 61)
        assertNil(
            await machine.complete(initial, result: .success(extraction(quota: quota)))
        )
        let refresh = try unwrap(await machine.invalidate(.notification))
        assertNil(
            await machine.complete(refresh, result: .success(extraction(quota: nil)))
        )

        assertEqual(await slowSubscriber.next(), .noWeeklyWindow)
    }

    func testCancelledSubscriberIsRemoved() async throws {
        let machine = makeMachine()
        let stream = machine.subscribeStates()
        assertEqual(machine.subscriberCountForTesting, 1)
        let consumer = Task {
            for await _ in stream {}
        }

        await Task.yield()
        consumer.cancel()
        _ = try await withTimeout {
            await consumer.value
            return true
        }

        for _ in 0..<100 where machine.subscriberCountForTesting != 0 {
            await Task.yield()
        }
        assertEqual(machine.subscriberCountForTesting, 0)
    }

    func testProducerTeardownFinishesSubscribersWithoutHanging() async throws {
        var machine: QuotaRefreshMachine? = makeMachine()
        let stream = try XCTUnwrap(machine?.subscribeStates())
        machine = nil

        let received = try await withTimeout {
            var iterator = stream.makeAsyncIterator()
            var values: [QuotaDisplayState] = []
            while let value = await iterator.next() {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(received, [.loading])
    }

    private func makeMachine() -> QuotaRefreshMachine {
        QuotaRefreshMachine(clock: FixedQuotaClock(now: now))
    }

    private func extraction(quota: WeeklyQuota?) -> WeeklyQuotaExtraction {
        WeeklyQuotaExtraction(quota: quota, warnings: [])
    }

    private func freshQuota(remainingPercent: Int = 64) -> WeeklyQuota {
        WeeklyQuota(
            remainingPercent: remainingPercent,
            resetsAt: now.addingTimeInterval(3_600),
            fingerprint: "fresh-\(remainingPercent)"
        )
    }

    private func expiredQuota(fingerprint: String) -> WeeklyQuota {
        WeeklyQuota(
            remainingPercent: 50,
            resetsAt: now,
            fingerprint: fingerprint
        )
    }

    private func unwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func assertNil<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(value, file: file, line: line)
    }

    private func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private enum TestError: Error {
    case transport
}

private enum AsyncTestTimeout: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await ContinuousClock().sleep(for: .seconds(1))
            throw AsyncTestTimeout.timedOut
        }

        let next = try await group.next()
        let result = try XCTUnwrap(next)
        group.cancelAll()
        return result
    }
}

private final class ManualQuotaClock: QuotaClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedWallNow: Date
    private var storedMonotonicNow: TimeInterval

    init(wallNow: Date, monotonicNow: TimeInterval) {
        storedWallNow = wallNow
        storedMonotonicNow = monotonicNow
    }

    var now: Date {
        wallNow
    }

    var wallNow: Date {
        lock.lock()
        defer { lock.unlock() }
        return storedWallNow
    }

    var monotonicNow: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedMonotonicNow
    }

    func setWallNow(_ value: Date) {
        lock.lock()
        storedWallNow = value
        lock.unlock()
    }

    func setMonotonicNow(_ value: TimeInterval) {
        lock.lock()
        storedMonotonicNow = value
        lock.unlock()
    }
}
