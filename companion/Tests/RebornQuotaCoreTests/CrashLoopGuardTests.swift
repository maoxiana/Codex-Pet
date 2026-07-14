import Foundation
import XCTest
@testable import RebornQuotaCore

final class CrashLoopGuardTests: XCTestCase {
    func testThreeIncompleteLaunchesWithinFiveMinutesSuppressNextRelaunch() throws {
        let storage = MemoryCrashLoopStorage()
        let clock = MutableCrashClock(Date(timeIntervalSince1970: 10_000))
        var guardrail = CrashLoopGuard(storage: storage, clock: clock)

        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        clock.advance(60)
        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        clock.advance(60)
        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        clock.advance(60)
        XCTAssertEqual(try guardrail.beginLaunch(), .exitSuccessfully)

        XCTAssertEqual(try storage.load()?.recentFailureDates.count, 3)
    }

    func testFailureOutsideFiveMinuteWindowIsPruned() throws {
        let storage = MemoryCrashLoopStorage()
        let clock = MutableCrashClock(Date(timeIntervalSince1970: 20_000))
        var guardrail = CrashLoopGuard(storage: storage, clock: clock)

        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        clock.advance(301)
        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        XCTAssertEqual(try storage.load()?.recentFailureDates.count, 1)
    }

    func testHealthyForTenMinutesClearsFailuresAndActiveMarker() throws {
        let storage = MemoryCrashLoopStorage()
        let clock = MutableCrashClock(Date(timeIntervalSince1970: 30_000))
        var guardrail = CrashLoopGuard(storage: storage, clock: clock)

        _ = try guardrail.beginLaunch()
        clock.advance(60)
        _ = try guardrail.beginLaunch()
        clock.advance(600)

        XCTAssertTrue(try guardrail.markHealthyIfEligible())
        XCTAssertEqual(try storage.load(), .empty)
    }

    func testStorageAndClockAreInjectedAndStateRoundTripsAsJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-crash-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("runtime-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JSONFileCrashLoopStorage(url: url)
        let clock = MutableCrashClock(Date(timeIntervalSince1970: 40_000))
        var guardrail = CrashLoopGuard(storage: storage, clock: clock)

        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        XCTAssertEqual(try storage.load()?.activeLaunchStartedAt, clock.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptAdvisoryStateDoesNotPermanentlyDisableLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-corrupt-crash-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("runtime-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        let storage = JSONFileCrashLoopStorage(url: url)
        let clock = MutableCrashClock(Date(timeIntervalSince1970: 50_000))
        var guardrail = CrashLoopGuard(storage: storage, clock: clock)

        XCTAssertEqual(try guardrail.beginLaunch(), .continueLaunching)
        XCTAssertEqual(try storage.load()?.activeLaunchStartedAt, clock.now)
    }
}

private final class MemoryCrashLoopStorage: CrashLoopStorage, @unchecked Sendable {
    private var state: CrashLoopState?

    func load() throws -> CrashLoopState? { state }
    func save(_ state: CrashLoopState) throws { self.state = state }
}

private final class MutableCrashClock: CrashLoopClock, @unchecked Sendable {
    var now: Date

    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
