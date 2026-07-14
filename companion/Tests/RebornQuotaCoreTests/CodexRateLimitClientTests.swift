import Foundation
import XCTest
@testable import RebornQuotaCore

final class CodexRateLimitClientTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")

    func testInitializeInitializedAndReadAreSentInExactOrder() async throws {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        process.yieldStdout(rateLimitResponse(id: 2, usedPercent: 25))
        let scheduler = RecordingScheduler()
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: scheduler
        )

        let extraction = try await client.fetchOnce(executable: executable)

        XCTAssertEqual(extraction.quota?.remainingPercent, 75)
        let lines = try process.writtenLines.map(decodeObject)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0]["id"] as? Int, 1)
        XCTAssertEqual(lines[0]["method"] as? String, "initialize")
        let params = try XCTUnwrap(lines[0]["params"] as? [String: Any])
        XCTAssertEqual((params["clientInfo"] as? [String: Any])?["name"] as? String, "reborn-quota")
        XCTAssertEqual((params["clientInfo"] as? [String: Any])?["title"] as? String, "Reborn Quota")
        XCTAssertEqual((params["clientInfo"] as? [String: Any])?["version"] as? String, "0.1.0")
        XCTAssertEqual((params["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool, true)
        XCTAssertNil(lines[0]["jsonrpc"])
        XCTAssertEqual(lines[1]["method"] as? String, "initialized")
        XCTAssertEqual(Set(lines[1].keys), ["method"])
        XCTAssertEqual(lines[2]["id"] as? Int, 2)
        XCTAssertEqual(lines[2]["method"] as? String, "account/rateLimits/read")
        XCTAssertTrue(lines[2]["params"] is NSNull)
        XCTAssertEqual(scheduler.sleeps.prefix(2), [.seconds(5), .seconds(8)])
        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testUpdateBeforeFirstSnapshotAndDuplicatesDuringReadCoalesceToOneFollowUp() async throws {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        process.yieldStdout(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":99,"windowDurationMins":10080}}}}"#
        )
        process.yieldStdout(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":98,"windowDurationMins":10080}}}}"#
        )
        process.yieldStdout(rateLimitResponse(id: 2, usedPercent: 60))
        process.yieldStdout(rateLimitResponse(id: 3, usedPercent: 20))
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler()
        )

        let extraction = try await client.readOnce(executable: executable)

        XCTAssertEqual(extraction.quota?.remainingPercent, 80)
        let lines = try process.writtenLines.map(decodeObject)
        XCTAssertEqual(lines.map { $0["method"] as? String }, [
            "initialize", "initialized", "account/rateLimits/read", "account/rateLimits/read",
        ])
        XCTAssertEqual(lines[3]["id"] as? Int, 3)
    }

    func testUnknownNotificationAndResponseFieldsAreTolerated() async throws {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1, extra: #", "future": true"#))
        process.yieldStdout(#"{"method":"future/notification","params":null,"added":42}"#)
        process.yieldStdout(rateLimitResponse(id: 2, usedPercent: 44, extra: #", "future": {"x":1}"#))
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler()
        )

        let extraction = try await client.readOnce(executable: executable)

        XCTAssertEqual(extraction.quota?.remainingPercent, 56)
    }

    func testAuthenticationErrorIsNormalizedAndChildIsAlwaysTerminated() async {
        let process = ClientFakeLineProcess()
        process.yieldStdout(#"{"id":1,"error":{"code":-32000,"message":"authentication required"}}"#)
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler()
        )

        await AssertAsyncThrows(try await client.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .authenticationRequired)
        }
        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testAnyNonAuthenticationInitializeErrorIsIncompatibleProtocol() async {
        let process = ClientFakeLineProcess()
        process.yieldStdout(#"{"id":1,"error":{"code":-32042,"message":"initialize failed"}}"#)
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler()
        )

        await AssertAsyncThrows(try await client.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .incompatibleProtocol)
        }
    }

    func testReadResponseErrorIsTypedWithoutPayloadExposure() async {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        process.yieldStdout(#"{"id":2,"error":{"code":-32042,"message":"server failure"}}"#)
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler()
        )

        await AssertAsyncThrows(try await client.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .responseError(code: -32042))
        }
        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testMissingAndInvalidRequiredResultsAreIncompatibleProtocol() async {
        let missing = ClientFakeLineProcess()
        missing.yieldStdout(#"{"id":1}"#)
        let missingClient = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: missing),
            scheduler: RecordingScheduler()
        )
        await AssertAsyncThrows(try await missingClient.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .incompatibleProtocol)
        }

        let invalid = ClientFakeLineProcess()
        invalid.yieldStdout(initializeResponse(id: 1))
        invalid.yieldStdout(#"{"id":2,"result":null}"#)
        let invalidClient = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: invalid),
            scheduler: RecordingScheduler()
        )
        await AssertAsyncThrows(try await invalidClient.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .incompatibleProtocol)
        }
    }

    func testInitializeTimeoutUsesFiveSecondsAndTwoSecondShutdownWithoutSleeping() async {
        let process = ClientFakeLineProcess()
        let scheduler = ImmediateScheduler()
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: scheduler
        )

        await AssertAsyncThrows(try await client.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .timeout(.initialize))
        }
        XCTAssertEqual(scheduler.sleeps, [.seconds(5)])
        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testReadTimeoutUsesEightSecondsWithoutSleeping() async {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        let scheduler = StageScheduler(immediateAt: .seconds(8))
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: scheduler
        )

        await AssertAsyncThrows(try await client.readOnce(executable: executable)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .timeout(.read))
        }
        XCTAssertEqual(scheduler.sleeps, [.seconds(5), .seconds(8)])
    }

    func testRunStaysConnectedForNotificationDirtyFollowUpAndSafetyRefresh() async throws {
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        process.yieldStdout(rateLimitResponse(id: 2, usedPercent: 50))
        let scheduler = ControllableScheduler()
        let machine = QuotaRefreshMachine()
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: scheduler,
            refreshMachine: machine
        )
        let executable = self.executable
        let runTask = Task {
            try await client.runUntilCancelled(executable: executable)
        }

        try await eventually {
            process.writtenLines.count == 3 && scheduler.hasWaiter(for: .seconds(60))
        }
        process.yieldStdout(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":99}}}}"#
        )
        try await eventually { process.writtenLines.count == 4 }
        process.yieldStdout(
            #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"secondary":{"usedPercent":98}}}}"#
        )
        process.yieldStdout(rateLimitResponse(id: 3, usedPercent: 40))
        try await eventually { process.writtenLines.count == 5 }
        process.yieldStdout(rateLimitResponse(id: 4, usedPercent: 30))
        try await eventually {
            guard case .available(let quota, _) = await machine.currentState else { return false }
            return quota.remainingPercent == 70
        }

        scheduler.fire(.seconds(60))
        try await eventually { process.writtenLines.count == 6 }
        process.yieldStdout(rateLimitResponse(id: 5, usedPercent: 20))
        try await eventually {
            guard case .available(let quota, _) = await machine.currentState else { return false }
            return quota.remainingPercent == 80
        }

        let methods = try process.writtenLines.map(decodeObject).map { $0["method"] as? String }
        XCTAssertEqual(methods, [
            "initialize", "initialized", "account/rateLimits/read",
            "account/rateLimits/read", "account/rateLimits/read", "account/rateLimits/read",
        ])
        XCTAssertEqual(scheduler.recordedSleeps.filter { $0 == .seconds(60) }.count, 2)

        runTask.cancel()
        await AssertAsyncThrows(try await runTask.value) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .cancelled)
        }
        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testReconnectBackoffIsCappedAndHealthySnapshotResetsPolicy() {
        var backoff = CodexReconnectBackoff()

        XCTAssertEqual((0..<7).map { _ in backoff.delayAfterFailure() }, [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8),
            .seconds(30), .seconds(30), .seconds(30),
        ])

        backoff.markHealthyAfterSnapshot()
        XCTAssertEqual(backoff.delayAfterFailure(), .seconds(1))
    }

    func testRunDetectsPostSnapshotEOFAndReconnectsAfterOneSecond() async throws {
        let first = ClientFakeLineProcess()
        first.yieldStdout(initializeResponse(id: 1))
        first.yieldStdout(rateLimitResponse(id: 2, usedPercent: 80))
        first.finishStdout()
        let second = ClientFakeLineProcess()
        second.yieldStdout(initializeResponse(id: 1))
        second.yieldStdout(rateLimitResponse(id: 2, usedPercent: 10))
        let scheduler = ControllableScheduler()
        let machine = QuotaRefreshMachine()
        let client = CodexRateLimitClient(
            processFactory: QueueProcessFactory(processes: [first, second]),
            scheduler: scheduler,
            refreshMachine: machine
        )
        let executable = self.executable
        let runTask = Task {
            try await client.runUntilCancelled(executable: executable)
        }

        try await eventually {
            scheduler.hasWaiter(for: .seconds(1)) && first.stdinClosed
        }
        scheduler.fire(.seconds(1))
        try await eventually {
            guard second.writtenLines.count == 3,
                  case .available(let quota, _) = await machine.currentState else { return false }
            return quota.remainingPercent == 90
        }

        XCTAssertEqual(
            scheduler.recordedSleeps.filter { $0 == .seconds(1) },
            [.seconds(1)]
        )
        runTask.cancel()
        await AssertAsyncThrows(try await runTask.value) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .cancelled)
        }
        XCTAssertTrue(first.stdinClosed)
        XCTAssertTrue(second.stdinClosed)
    }

    func testMismatchedRuntimeEmitsOnlySanitizedWarningAndStillFetches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-mismatch-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let identity = try XCTUnwrap(CodexExecutableIdentity.capture(at: executable))
        let process = ClientFakeLineProcess()
        process.yieldStdout(initializeResponse(id: 1))
        process.yieldStdout(rateLimitResponse(id: 2, usedPercent: 25))
        let warnings = RecordingWarningSink()
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: RecordingScheduler(),
            warningSink: warnings
        )
        let located = LocatedCodexExecutable(
            url: executable,
            reportedVersion: "codex-cli private-version",
            matchesPinnedVersion: false,
            identity: identity
        )

        let extraction = try await client.fetchOnce(executable: located)

        XCTAssertEqual(extraction.quota?.remainingPercent, 75)
        XCTAssertEqual(warnings.warnings, [.runtimeVersionMismatch])
        XCTAssertEqual(
            CodexProtocolWarning.runtimeVersionMismatch.diagnosticMessage,
            "warning: Codex CLI version differs from the pinned quota protocol; attempting compatible initialization"
        )
        XCTAssertFalse(
            CodexProtocolWarning.runtimeVersionMismatch.diagnosticMessage.contains(located.url.path)
        )
        XCTAssertFalse(
            CodexProtocolWarning.runtimeVersionMismatch.diagnosticMessage.contains(located.reportedVersion)
        )
    }

    func testReplacingLocatedExecutableIsRejectedBeforeEveryLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-locator-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": executable.path],
            homeDirectory: directory,
            inspector: FoundationCodexExecutableInspector(),
            versionProber: StaticVersionProber()
        )
        let located = try await locator.locate()
        try FileManager.default.removeItem(at: executable)
        try writeExecutable("#!/bin/sh\nexit 1\n", to: executable)
        let factory = CountingProcessFactory(process: ClientFakeLineProcess())
        let client = CodexRateLimitClient(
            processFactory: factory,
            scheduler: RecordingScheduler()
        )

        await AssertAsyncThrows(try await client.fetchOnce(executable: located)) { error in
            XCTAssertEqual(error as? CodexRateLimitClientError, .executableChanged)
        }
        XCTAssertEqual(factory.startCount, 0)
    }

    func testCancellationClosesStdinAndTerminatesOwnedHungChild() async {
        let process = ClientFakeLineProcess()
        let scheduler = RecordingScheduler()
        let client = CodexRateLimitClient(
            processFactory: SingleProcessFactory(process: process),
            scheduler: scheduler
        )
        let executable = self.executable
        let task = Task {
            try await client.readOnce(executable: executable)
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        task.cancel()
        _ = try? await task.value

        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
        XCTAssertTrue(process.stdinClosed)
    }

    func testEachConnectionAdvancesEpochSoOldTokensCannotPublish() async throws {
        let machine = QuotaRefreshMachine()
        let first = ClientFakeLineProcess()
        first.yieldStdout(initializeResponse(id: 1))
        first.yieldStdout(rateLimitResponse(id: 2, usedPercent: 80))
        let second = ClientFakeLineProcess()
        second.yieldStdout(initializeResponse(id: 1))
        second.yieldStdout(rateLimitResponse(id: 2, usedPercent: 10))
        let factory = QueueProcessFactory(processes: [first, second])
        let client = CodexRateLimitClient(
            processFactory: factory,
            scheduler: RecordingScheduler(),
            refreshMachine: machine
        )

        _ = try await client.readOnce(executable: executable)
        _ = try await client.readOnce(executable: executable)

        guard case .available(let quota, _) = await machine.currentState else {
            return XCTFail("Expected available state")
        }
        XCTAssertEqual(quota.remainingPercent, 90)
    }

    func testNormalizedProbeOutputIncludesExplicitNullsAndNoRawProtocolFields() throws {
        let unavailable = CodexRateLimitProbeOutput.unavailable
        let unavailableObject = try decodeObject(JSONEncoder().encode(unavailable))
        XCTAssertEqual(Set(unavailableObject.keys), [
            "status", "limitId", "durationMins", "remainingPercent", "hasResetTime",
        ])
        XCTAssertEqual(unavailableObject["status"] as? String, "unavailable")
        XCTAssertTrue(unavailableObject["limitId"] is NSNull)
        XCTAssertTrue(unavailableObject["durationMins"] is NSNull)
        XCTAssertTrue(unavailableObject["remainingPercent"] is NSNull)
        XCTAssertEqual(unavailableObject["hasResetTime"] as? Bool, false)

        let extraction = WeeklyQuotaExtraction(
            quota: WeeklyQuota(
                remainingPercent: 73,
                resetsAt: Date(timeIntervalSince1970: 2_100_000_000),
                fingerprint: "not-public"
            ),
            warnings: ["not-public"]
        )
        let availableObject = try decodeObject(
            JSONEncoder().encode(CodexRateLimitProbeOutput(extraction: extraction))
        )
        XCTAssertEqual(availableObject["status"] as? String, "available")
        XCTAssertEqual(availableObject["limitId"] as? String, "codex")
        XCTAssertEqual(availableObject["durationMins"] as? Int, 10_080)
        XCTAssertEqual(availableObject["remainingPercent"] as? Int, 73)
        XCTAssertEqual(availableObject["hasResetTime"] as? Bool, true)
        XCTAssertNil(availableObject["fingerprint"])
        XCTAssertNil(availableObject["warnings"])
    }

    func testNormalizedProbeOutputDistinguishesNoWeeklyWindow() throws {
        let output = CodexRateLimitProbeOutput(
            extraction: WeeklyQuotaExtraction(quota: nil, warnings: [])
        )
        let object = try decodeObject(JSONEncoder().encode(output))

        XCTAssertEqual(object["status"] as? String, "noWeeklyWindow")
        XCTAssertTrue(object["limitId"] is NSNull)
        XCTAssertTrue(object["durationMins"] is NSNull)
        XCTAssertTrue(object["remainingPercent"] is NSNull)
        XCTAssertEqual(object["hasResetTime"] as? Bool, false)
    }
}

private final class ClientFakeLineProcess: LineProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<Data, Error>
    let stderrLines: AsyncStream<Data>
    private var writeStorage: [Data] = []
    private var graceStorage: [Duration] = []
    private var stdinClosedStorage = false

    init() {
        let stdoutPair = AsyncThrowingStream<Data, Error>.makeStream()
        stdoutLines = stdoutPair.stream
        stdoutContinuation = stdoutPair.continuation
        stderrLines = AsyncStream { continuation in continuation.finish() }
    }

    var writtenLines: [Data] { lock.withLock { writeStorage } }
    var terminationGraces: [Duration] { lock.withLock { graceStorage } }
    var stdinClosed: Bool { lock.withLock { stdinClosedStorage } }

    func writeLine(_ data: Data) async throws {
        lock.withLock { writeStorage.append(data) }
    }

    func terminate(grace: Duration) async {
        lock.withLock {
            graceStorage.append(grace)
            stdinClosedStorage = true
        }
        stdoutContinuation.finish()
    }

    func yieldStdout(_ string: String) {
        stdoutContinuation.yield(Data(string.utf8))
    }

    func finishStdout() {
        stdoutContinuation.finish()
    }
}

private struct SingleProcessFactory: CodexProcessFactory {
    let process: ClientFakeLineProcess

    func start(executable: URL) throws -> any LineProcess {
        _ = executable
        return process
    }
}

private final class CountingProcessFactory: CodexProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let process: ClientFakeLineProcess
    private var count = 0

    init(process: ClientFakeLineProcess) {
        self.process = process
    }

    var startCount: Int { lock.withLock { count } }

    func start(executable: URL) throws -> any LineProcess {
        _ = executable
        lock.withLock { count += 1 }
        return process
    }
}

private struct StaticVersionProber: CodexVersionProbing {
    func version(of executable: URL, timeout: Duration) async throws -> String {
        _ = executable
        _ = timeout
        return CodexExecutableLocator.pinnedVersion
    }
}

private final class QueueProcessFactory: CodexProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ClientFakeLineProcess]

    init(processes: [ClientFakeLineProcess]) {
        self.processes = processes
    }

    func start(executable: URL) throws -> any LineProcess {
        _ = executable
        return lock.withLock { processes.removeFirst() }
    }
}

private final class RecordingScheduler: AppServerScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepStorage: [Duration] = []

    var sleeps: [Duration] { lock.withLock { sleepStorage } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { sleepStorage.append(duration) }
        try await Task.sleep(for: .seconds(3_600))
    }
}

private final class ImmediateScheduler: AppServerScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepStorage: [Duration] = []

    var sleeps: [Duration] { lock.withLock { sleepStorage } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { sleepStorage.append(duration) }
    }
}

private final class StageScheduler: AppServerScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private let immediateAt: Duration
    private var sleepStorage: [Duration] = []

    init(immediateAt: Duration) {
        self.immediateAt = immediateAt
    }

    var sleeps: [Duration] { lock.withLock { sleepStorage } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { sleepStorage.append(duration) }
        if duration == immediateAt {
            return
        }
        try await Task.sleep(for: .seconds(3_600))
    }
}

private final class ControllableScheduler: AppServerScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: (Duration, AsyncThrowingStream<Void, Error>.Continuation)] = [:]
    private var sleepStorage: [Duration] = []

    var recordedSleeps: [Duration] { lock.withLock { sleepStorage } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let pair = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            sleepStorage.append(duration)
            continuations[id] = (duration, pair.continuation)
        }
        defer {
            _ = lock.withLock { continuations.removeValue(forKey: id) }
        }
        try await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            guard try await iterator.next() != nil else {
                throw CancellationError()
            }
        } onCancel: {
            pair.continuation.finish(throwing: CancellationError())
        }
    }

    func hasWaiter(for duration: Duration) -> Bool {
        lock.withLock { continuations.values.contains { $0.0 == duration } }
    }

    func fire(_ duration: Duration) {
        let matches = lock.withLock {
            continuations.values.filter { $0.0 == duration }.map(\.1)
        }
        for continuation in matches {
            continuation.yield(())
            continuation.finish()
        }
    }
}

private final class RecordingWarningSink: CodexWarningSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexProtocolWarning] = []

    var warnings: [CodexProtocolWarning] { lock.withLock { storage } }

    func emit(_ warning: CodexProtocolWarning) {
        lock.withLock { storage.append(warning) }
    }
}

private func initializeResponse(id: Int, extra: String = "") -> String {
    """
    {"id":\(id),"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"codex"\(extra)}}
    """
}

private func rateLimitResponse(id: Int, usedPercent: Int, extra: String = "") -> String {
    """
    {"id":\(id),"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":\(usedPercent),"windowDurationMins":10080,"resetsAt":2100000000}}\(extra)}}
    """
}

private func decodeObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
    )
}

private func AssertAsyncThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private enum EventuallyError: Error {
    case timedOut
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() {
            return
        }
        try await clock.sleep(for: .milliseconds(2))
    }
    throw EventuallyError.timedOut
}
