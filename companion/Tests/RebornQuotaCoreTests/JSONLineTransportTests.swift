import Foundation
import XCTest
@testable import RebornQuotaCore
#if canImport(Darwin)
import Darwin
#endif

final class JSONLineTransportTests: XCTestCase {
    func testRequestEncodingUsesNewlineEnvelopeWithoutJSONRPCAndPreservesNullParams() async throws {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)

        try await transport.sendRequest(
            id: .number(1),
            method: "account/rateLimits/read",
            params: .null
        )

        let lines = process.writtenLines
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lines[0]) as? [String: Any]
        )
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "account/rateLimits/read")
        XCTAssertTrue(object["params"] is NSNull)
        XCTAssertNil(object["jsonrpc"])
    }

    func testRequestEncodingPreservesIntegerIDsAboveDoublePrecision() async throws {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        let id: Int64 = 9_007_199_254_740_993

        try await transport.sendRequest(id: .number(id), method: "large-id", params: .null)

        let encoded = try XCTUnwrap(process.writtenLines.first)
        XCTAssertTrue(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("9007199254740993"))
        XCTAssertEqual(
            try JSONDecoder().decode(EncodedRequestID.self, from: encoded).id,
            id
        )
    }

    func testResponsesMayArriveOutOfOrderAndRemainCorrelatedByRequestID() async throws {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        try await transport.sendRequest(id: .number(1), method: "one", params: .object([:]))
        try await transport.sendRequest(id: .number(2), method: "two", params: .null)
        process.yieldStdout(#"{"id":2,"result":{"name":"second"},"future":true}"#)
        process.yieldStdout(#"{"id":1,"result":{"name":"first"}}"#)

        let second = try await transport.nextEvent()
        let first = try await transport.nextEvent()

        XCTAssertEqual(second.id, .number(2))
        XCTAssertEqual(second.result?["name"], .string("second"))
        XCTAssertEqual(first.id, .number(1))
        XCTAssertEqual(first.result?["name"], .string("first"))
    }

    func testUnknownNotificationAndUnknownFieldsAreTolerated() async throws {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        process.yieldStdout(
            #"{"method":"future/event","params":{"added":1},"unknown":{"nested":true}}"#
        )

        let event = try await transport.nextEvent()

        XCTAssertEqual(event.method, "future/event")
        XCTAssertEqual(event.params?["added"], .integer(1))
    }

    func testJSONValuePreservesInt64ExtremesAndFloatingNumbers() throws {
        let source = Data(
            #"{"maximum":9223372036854775807,"minimum":-9223372036854775808,"fraction":1.25}"#.utf8
        )

        let value = try JSONDecoder().decode(JSONValue.self, from: source)
        XCTAssertEqual(value["maximum"], .integer(.max))
        XCTAssertEqual(value["minimum"], .integer(.min))
        XCTAssertEqual(value["fraction"], .number(1.25))

        let encoded = try JSONEncoder().encode(value)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(roundTrip, value)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("9223372036854775807"))
        XCTAssertTrue(text.contains("-9223372036854775808"))
    }

    func testMalformedJSONFailsTyped() async {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        process.yieldStdout("not-json")

        await XCTAssertThrowsErrorAsync(try await transport.nextEvent()) { error in
            XCTAssertEqual(error as? JSONLineTransportError, .malformedJSON)
        }
    }

    func testOversizeLineFailsBeforeDecode() async {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process, maximumLineBytes: 16)
        process.yieldStdout(String(repeating: "x", count: 17))

        await XCTAssertThrowsErrorAsync(try await transport.nextEvent()) { error in
            XCTAssertEqual(error as? JSONLineTransportError, .lineTooLong(maximumBytes: 16))
        }
    }

    func testCleanEOFIsTyped() async {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        process.finishStdout()

        await XCTAssertThrowsErrorAsync(try await transport.nextEvent()) { error in
            XCTAssertEqual(error as? JSONLineTransportError, .endOfFile)
        }
    }

    func testWrongAndDuplicateResponseIDsFailTyped() async throws {
        let wrongProcess = FakeLineProcess()
        let wrongTransport = JSONLineTransport(process: wrongProcess)
        try await wrongTransport.sendRequest(id: .number(1), method: "one", params: .null)
        wrongProcess.yieldStdout(#"{"id":99,"result":{}}"#)
        await XCTAssertThrowsErrorAsync(try await wrongTransport.nextEvent()) { error in
            XCTAssertEqual(
                error as? JSONLineTransportError,
                .unexpectedResponseID(.number(99))
            )
        }

        let duplicateProcess = FakeLineProcess()
        let duplicateTransport = JSONLineTransport(process: duplicateProcess)
        try await duplicateTransport.sendRequest(id: .number(7), method: "seven", params: .null)
        duplicateProcess.yieldStdout(#"{"id":7,"result":{}}"#)
        duplicateProcess.yieldStdout(#"{"id":7,"result":{}}"#)
        _ = try await duplicateTransport.nextEvent()
        await XCTAssertThrowsErrorAsync(try await duplicateTransport.nextEvent()) { error in
            XCTAssertEqual(
                error as? JSONLineTransportError,
                .duplicateResponseID(.number(7))
            )
        }
    }

    func testCompletedResponseIDsUseBoundedReplayWindow() async throws {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)

        for value in 1...270 {
            try await transport.sendRequest(id: .number(Int64(value)), method: "read", params: .null)
            process.yieldStdout(#"{"id":\#(value),"result":{}}"#)
            _ = try await transport.nextEvent()
        }

        // The oldest ID is outside the 256-entry replay window and may be reused.
        try await transport.sendRequest(id: .number(1), method: "read-again", params: .null)
        process.yieldStdout(#"{"id":1,"result":{"fresh":true}}"#)
        let reused = try await transport.nextEvent()
        XCTAssertEqual(reused.result?["fresh"], .bool(true))

        // A duplicate still inside the replay window remains typed.
        process.yieldStdout(#"{"id":270,"result":{}}"#)
        await XCTAssertThrowsErrorAsync(try await transport.nextEvent()) { error in
            XCTAssertEqual(error as? JSONLineTransportError, .duplicateResponseID(.number(270)))
        }
    }

    func testConcurrentNextEventIsRejectedInsteadOfSharingIterator() async {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)
        let first = Task { try await transport.nextEvent() }
        for _ in 0..<20 { await Task.yield() }

        await XCTAssertThrowsErrorAsync(
            try await withIntegrationTimeout(.milliseconds(200)) {
                try await transport.nextEvent()
            }
        ) { error in
            XCTAssertEqual(error as? JSONLineTransportError, .concurrentRead)
        }

        process.finishStdout()
        _ = try? await first.value
    }

    func testCloseDelegatesTwoSecondGraceToOwnedProcess() async {
        let process = FakeLineProcess()
        let transport = JSONLineTransport(process: process)

        await transport.close(grace: .seconds(2))

        XCTAssertEqual(process.terminationGraces, [.seconds(2)])
    }

    func testBoundedDiagnosticBufferRetainsOnlyLast64KiB() {
        let buffer = BoundedDiagnosticBuffer(maximumBytes: 64 * 1_024)
        buffer.append(Data(repeating: 0x41, count: 48 * 1_024))
        buffer.append(Data(repeating: 0x42, count: 48 * 1_024))

        XCTAssertEqual(buffer.byteCount, 64 * 1_024)
        XCTAssertEqual(buffer.snapshot.prefix(16 * 1_024), Data(repeating: 0x41, count: 16 * 1_024))
        XCTAssertEqual(buffer.snapshot.suffix(48 * 1_024), Data(repeating: 0x42, count: 48 * 1_024))
    }

    func testProductionExecutablePrecedenceUsesInstallerPathThenApplicationsThenUserApplications() async throws {
        let installer = URL(fileURLWithPath: "/opt/reborn/codex")
        let system = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let user = URL(fileURLWithPath: "/Users/test/Applications/ChatGPT.app/Contents/Resources/codex")
        let inspector = FakeCodexExecutableInspector(valid: [installer, system, user])
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": installer.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            allowDevelopmentPATH: false,
            inspector: inspector,
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )

        let located = try await locator.locate()

        XCTAssertEqual(located.url, installer)
        XCTAssertTrue(located.matchesPinnedVersion)
        XCTAssertEqual(inspector.inspected.first, installer)
    }

    func testRelativeConfiguredPathIsRejectedBeforeFallback() async {
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": "bin/codex"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: FakeCodexExecutableInspector(valid: []),
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .configuredPathMustBeAbsolute)
        }
    }

    func testNonExecutableCandidatesBecomeTypedUnavailable() async {
        let locator = CodexExecutableLocator(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            allowDevelopmentPATH: false,
            inspector: FakeCodexExecutableInspector(valid: []),
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .unavailable)
        }
    }

    func testPATHIsConsideredOnlyInExplicitDevelopmentMode() async throws {
        let pathCodex = URL(fileURLWithPath: "/dev-tools/bin/codex")
        let inspector = FakeCodexExecutableInspector(valid: [pathCodex])
        let production = CodexExecutableLocator(
            environment: ["PATH": "/dev-tools/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            allowDevelopmentPATH: false,
            inspector: inspector,
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )
        await XCTAssertThrowsErrorAsync(try await production.locate()) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .unavailable)
        }

        let development = CodexExecutableLocator(
            environment: ["PATH": "/dev-tools/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            allowDevelopmentPATH: true,
            inspector: inspector,
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )
        let located = try await development.locate()
        XCTAssertEqual(located.url, pathCodex)
    }

    func testVersionProbeUsesTwoSecondTimeoutAndMismatchIsReportedNotRejected() async throws {
        let executable = URL(fileURLWithPath: "/opt/codex")
        let prober = FakeCodexVersionProber(output: "codex-cli 0.145.0")
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": executable.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: FakeCodexExecutableInspector(valid: [executable]),
            versionProber: prober
        )

        let located = try await locator.locate()

        XCTAssertEqual(prober.timeouts, [.seconds(2)])
        XCTAssertFalse(located.matchesPinnedVersion)
        XCTAssertEqual(located.reportedVersion, "codex-cli 0.145.0")
    }

    func testInvalidConfiguredAbsolutePathFailsClosedWithoutFallback() async {
        let configured = URL(fileURLWithPath: "/installer/missing-codex")
        let system = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let inspector = FakeCodexExecutableInspector(valid: [system])
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": configured.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: inspector,
            versionProber: FakeCodexVersionProber(output: "codex-cli 0.144.0-alpha.4")
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .configuredPathInvalid)
        }
        XCTAssertEqual(inspector.inspected, [configured])
    }

    func testConfiguredVersionProbeFailureFailsClosedWithoutFallback() async {
        let configured = URL(fileURLWithPath: "/installer/codex")
        let system = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        let inspector = FakeCodexExecutableInspector(valid: [configured, system])
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": configured.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: inspector,
            versionProber: ThrowingCodexVersionProber()
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .configuredVersionProbeFailed)
        }
        XCTAssertEqual(inspector.inspected, [configured])
    }

    func testLocatorRejectsInPlaceExecutableOverwriteDuringVersionProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-locator-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try writeExecutableScript("echo old", to: executable)
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": executable.path],
            homeDirectory: directory,
            inspector: FoundationCodexExecutableInspector(),
            versionProber: OverwritingCodexVersionProber(replacementBody: "echo new")
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(
                error as? CodexExecutableLocatorError,
                .executableChangedDuringVersionProbe
            )
        }
    }

    func testLocatorFailsTypedWhenExecutableIdentityCannotBeCaptured() async {
        let executable = URL(fileURLWithPath: "/configured/codex")
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": executable.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: IdentityFailingCodexExecutableInspector(valid: executable),
            versionProber: FakeCodexVersionProber(output: CodexExecutableLocator.pinnedVersion)
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(
                error as? CodexExecutableLocatorError,
                .executableIdentityUnavailable
            )
        }
    }

    func testLocatorFailsTypedWhenIdentityDisappearsAfterVersionProbe() async {
        let executable = URL(fileURLWithPath: "/configured/codex")
        let identity = CodexExecutableIdentity(
            device: 1,
            inode: 2,
            mode: 0o100700,
            size: 3,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )
        let inspector = SequencedIdentityCodexExecutableInspector(
            valid: executable,
            identities: [identity, nil]
        )
        let prober = FakeCodexVersionProber(output: CodexExecutableLocator.pinnedVersion)
        let locator = CodexExecutableLocator(
            environment: ["CODEX_CLI_PATH": executable.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            inspector: inspector,
            versionProber: prober
        )

        await XCTAssertThrowsErrorAsync(try await locator.locate()) { error in
            XCTAssertEqual(
                error as? CodexExecutableLocatorError,
                .executableIdentityUnavailable
            )
        }
        XCTAssertEqual(prober.timeouts, [.seconds(2)])
    }

    func testConcreteStderrDrainIsBoundedWhileStdoutProtocolContinues() async throws {
        let executable = try makeExecutableScript(
            """
            printf '%070000d' 0 >&2
            printf '{"method":"ready"}\\n'
            IFS= read -r ignored || true
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let process = try FoundationCodexProcessFactory().start(executable: executable)
        let diagnostics = try XCTUnwrap(process as? any FoundationLineProcessDiagnostics)
        let transport = JSONLineTransport(process: process)

        let event = try await withIntegrationTimeout(.seconds(2)) {
            try await transport.nextEvent()
        }
        XCTAssertEqual(event.method, "ready")
        for _ in 0..<100 where diagnostics.retainedDiagnosticByteCount < 64 * 1_024 {
            await Task.yield()
        }
        XCTAssertEqual(diagnostics.retainedDiagnosticByteCount, 64 * 1_024)
        XCTAssertLessThanOrEqual(
            diagnostics.maximumRetainedStderrStreamBytes,
            64 * 1_024
        )
        await transport.close(grace: .seconds(2))
    }

    func testConcreteStdoutRejectsOversizeUnterminatedFrameBeforeEOF() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for the concrete framing fixture")
        }
        let executable = try makeExecutableScript(
            """
            exec /usr/bin/python3 -c 'import sys,time; sys.stdout.write("x" * 1048577); sys.stdout.flush(); time.sleep(10)'
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let process = try FoundationCodexProcessFactory().start(executable: executable)
        let transport = JSONLineTransport(process: process)

        await XCTAssertThrowsErrorAsync(
            try await withIntegrationTimeout(.seconds(2)) {
                try await transport.nextEvent()
            }
        ) { error in
            XCTAssertEqual(
                error as? JSONLineTransportError,
                .lineTooLong(maximumBytes: JSONLineTransport.defaultMaximumLineBytes)
            )
        }
        await transport.close(grace: .seconds(2))
    }

    func testConcreteStdoutFloodFailsAtBoundedFrameCapacityAndCleansUp() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for the concrete flood fixture")
        }
        let executable = try makeExecutableScript(
            """
            exec /usr/bin/python3 -c 'import sys,time; [sys.stdout.write("{\\\"method\\\":\\\"tick\\\"}\\n") for _ in range(10000)]; sys.stdout.flush(); time.sleep(60)'
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let process = try FoundationCodexProcessFactory().start(executable: executable)
        let diagnostics = try XCTUnwrap(process as? any FoundationLineProcessDiagnostics)
        let transport = JSONLineTransport(process: process)

        try await Task.sleep(for: .milliseconds(100))
        var delivered = 0
        do {
            while true {
                _ = try await transport.nextEvent()
                delivered += 1
            }
        } catch {
            XCTAssertEqual(
                error as? JSONLineTransportError,
                .stdoutBackpressureExceeded(maximumBufferedFrames: 8)
            )
        }
        XCTAssertLessThanOrEqual(delivered, 8)
        await transport.close(grace: .seconds(2))
        #if canImport(Darwin)
        errno = 0
        XCTAssertEqual(kill(diagnostics.ownedProcessIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        #endif
    }

    func testRepeatedLaunchFailuresDoNotLeakFileDescriptors() throws {
        #if canImport(Darwin)
        let before = try openFileDescriptorCount()
        for _ in 0..<80 {
            XCTAssertThrowsError(
                try FoundationCodexProcessFactory().start(
                    executable: URL(fileURLWithPath: "/definitely/missing/reborn-codex")
                )
            )
        }
        let after = try openFileDescriptorCount()
        XCTAssertLessThanOrEqual(after - before, 3)
        #endif
    }

    func testImmediateExitNeverLosesFinalStdoutFrameOrStderrTail() async throws {
        let executable = try makeExecutableScript(
            """
            printf '{"method":"final"}\\n'
            printf 'tail' >&2
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }

        for _ in 0..<20 {
            let process = try FoundationCodexProcessFactory().start(executable: executable)
            let diagnostics = try XCTUnwrap(process as? any FoundationLineProcessDiagnostics)
            let transport = JSONLineTransport(process: process)
            let event = try await withIntegrationTimeout(.seconds(2)) {
                try await transport.nextEvent()
            }
            XCTAssertEqual(event.method, "final")
            await XCTAssertThrowsErrorAsync(
                try await withIntegrationTimeout(.seconds(2)) {
                    try await transport.nextEvent()
                }
            ) { error in
                XCTAssertEqual(error as? JSONLineTransportError, .endOfFile)
            }
            for _ in 0..<100 where diagnostics.retainedDiagnosticByteCount < 4 {
                await Task.yield()
            }
            XCTAssertEqual(diagnostics.retainedDiagnosticByteCount, 4)
            await transport.close(grace: .milliseconds(200))
        }
    }

    func testConcreteHungChildUsesSingleShutdownBudgetAndIsReaped() async throws {
        let executable = try makeExecutableScript(
            """
            trap '' TERM
            exec /bin/sleep 60
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let process = try FoundationCodexProcessFactory().start(executable: executable)
        let diagnostics = try XCTUnwrap(process as? any FoundationLineProcessDiagnostics)
        let pid = diagnostics.ownedProcessIdentifier
        let clock = ContinuousClock()
        let startedAt = clock.now

        await process.terminate(grace: .seconds(2))

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThanOrEqual(elapsed, .milliseconds(2_250))
        #if canImport(Darwin)
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        #endif
    }

    func testFoundationFactoryPinsReadOnlyStdioArguments() {
        XCTAssertEqual(FoundationCodexProcessFactory.appServerArguments, ["app-server", "--stdio"])
    }

    func testSchemaPinSwapRestoresBackupOnMoveFailureAndRerunsDeterministically() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceScript = packageRoot.appendingPathComponent("scripts/pin_protocol_schema.sh")
        let schemaFixture = packageRoot
            .appendingPathComponent("ProtocolSchemas/0.144.0-alpha.4")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-pin-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let companion = root.appendingPathComponent("companion")
        let scripts = companion.appendingPathComponent("scripts")
        let destination = companion
            .appendingPathComponent("ProtocolSchemas/0.144.0-alpha.4")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let copiedScript = scripts.appendingPathComponent("pin_protocol_schema.sh")
        try Data(contentsOf: sourceScript).write(to: copiedScript)
        try makeExecutable(copiedScript)
        try Data("original".utf8).write(to: destination.appendingPathComponent("original.marker"))

        let fakeCodex = root.appendingPathComponent("fake-codex")
        try writeExecutableScript(
            """
            if [[ "${1:-}" == "--version" ]]; then
              echo "codex-cli 0.144.0-alpha.4"
              exit 0
            fi
            out=""
            while [[ $# -gt 0 ]]; do
              if [[ "$1" == "--out" ]]; then out="$2"; shift 2; else shift; fi
            done
            mkdir -p "$out"
            cp -R "$SCHEMA_FIXTURE"/. "$out"/
            """,
            to: fakeCodex
        )
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin")
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        let moveWrapper = wrapperDirectory.appendingPathComponent("mv")
        try writeExecutableScript(
            """
            destination="${@: -1}"
            if [[ "$destination" == */ProtocolSchemas/0.144.0-alpha.4 ]] && [[ ! -e "$REBORN_FAIL_MARKER" ]]; then
              : > "$REBORN_FAIL_MARKER"
              exit 73
            fi
            exec /bin/mv "$@"
            """,
            to: moveWrapper
        )
        let failMarker = root.appendingPathComponent("move-failed")
        var failingEnvironment = ProcessInfo.processInfo.environment
        failingEnvironment["SCHEMA_FIXTURE"] = schemaFixture.path
        failingEnvironment["REBORN_FAIL_MARKER"] = failMarker.path
        failingEnvironment["PATH"] = "\(wrapperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"

        XCTAssertNotEqual(
            try runProcess(copiedScript, arguments: [fakeCodex.path], environment: failingEnvironment),
            0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("original.marker").path
            )
        )

        try writeExecutableScript(
            """
            source="${1:-}"
            destination="${@: -1}"
            if [[ "$source" == */ProtocolSchemas/0.144.0-alpha.4 ]] && [[ "$destination" == */.reborn-schema-backup.* ]]; then
              /bin/mv "$@"
              kill -TERM "$PPID"
              exit 0
            fi
            exec /bin/mv "$@"
            """,
            to: moveWrapper
        )
        XCTAssertNotEqual(
            try runProcess(copiedScript, arguments: [fakeCodex.path], environment: failingEnvironment),
            0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("original.marker").path
            )
        )

        var normalEnvironment = ProcessInfo.processInfo.environment
        normalEnvironment["SCHEMA_FIXTURE"] = schemaFixture.path
        XCTAssertEqual(
            try runProcess(copiedScript, arguments: [fakeCodex.path], environment: normalEnvironment),
            0
        )
        let firstSnapshot = try directorySnapshot(destination)
        XCTAssertEqual(Set(firstSnapshot.keys), expectedPinnedSchemaFiles)
        XCTAssertEqual(
            try runProcess(
                URL(fileURLWithPath: "/usr/bin/shasum"),
                arguments: [
                    "-a", "256", "-c",
                    "ProtocolSchemas/0.144.0-alpha.4/SHA256SUMS",
                ],
                environment: normalEnvironment,
                currentDirectory: companion
            ),
            0
        )
        XCTAssertEqual(
            try runProcess(copiedScript, arguments: [fakeCodex.path], environment: normalEnvironment),
            0
        )
        XCTAssertEqual(try directorySnapshot(destination), firstSnapshot)
    }

    func testVersionProbeTimeoutDrainsStderrKillsTermIgnoringChildAndReapsPID() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-version-pid-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: pidFile.path) {
                try? FileManager.default.removeItem(at: pidFile)
            }
        }
        let executable = try makeExecutableScript(
            """
            printf '%s' "$$" > "\(pidFile.path)"
            trap '' TERM
            while :; do printf '%04096d' 0 >&2; done
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }

        let task = Task {
            try await FoundationCodexVersionProber().version(
                of: executable,
                timeout: .seconds(2)
            )
        }
        let pid = try await readPIDEventually(from: pidFile)
        await XCTAssertThrowsErrorAsync(
            try await withIntegrationTimeout(.seconds(3)) { try await task.value }
        ) { error in
            XCTAssertEqual(error as? CodexExecutableLocatorError, .versionProbeFailed)
        }
        assertProcessIsGone(pid)
    }

    func testCancellingVersionProbeKillsAndReapsOwnedChild() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for the cancellation fixture")
        }
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-version-cancel-pid-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: pidFile.path) {
                try? FileManager.default.removeItem(at: pidFile)
            }
        }
        let executable = try makeExecutableScript(
            """
            printf '%s' "$$" > "\(pidFile.path)"
            exec /usr/bin/python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let task = Task {
            try await FoundationCodexVersionProber().version(of: executable, timeout: .seconds(2))
        }
        let pid = try await readPIDEventually(from: pidFile)

        task.cancel()
        await XCTAssertThrowsErrorAsync(
            try await withIntegrationTimeout(.seconds(3)) { try await task.value }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        assertProcessIsGone(pid)
    }

    func testPreCancelledQuickVersionProbeCannotReturnSuccess() async throws {
        let executable = try makeExecutableScript(
            """
            printf 'codex-cli 0.144.0-alpha.4\\n'
            """
        )
        defer { try? FileManager.default.removeItem(at: executable) }
        let task = Task {
            try await FoundationCodexVersionProber().version(of: executable, timeout: .seconds(2))
        }
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private struct EncodedRequestID: Decodable {
    let id: Int64
}

private final class FakeLineProcess: LineProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<Data, Error>
    let stderrLines: AsyncStream<Data>
    private var storage: [Data] = []
    private var graceStorage: [Duration] = []

    init() {
        let stdoutPair = AsyncThrowingStream<Data, Error>.makeStream()
        stdoutLines = stdoutPair.stream
        stdoutContinuation = stdoutPair.continuation
        stderrLines = AsyncStream { continuation in continuation.finish() }
    }

    var writtenLines: [Data] {
        lock.withLock { storage }
    }

    var terminationGraces: [Duration] {
        lock.withLock { graceStorage }
    }

    func writeLine(_ data: Data) async throws {
        lock.withLock { storage.append(data) }
    }

    func terminate(grace: Duration) async {
        lock.withLock { graceStorage.append(grace) }
        stdoutContinuation.finish()
    }

    func yieldStdout(_ string: String) {
        stdoutContinuation.yield(Data(string.utf8))
    }

    func finishStdout() {
        stdoutContinuation.finish()
    }
}

private final class FakeCodexExecutableInspector: CodexExecutableInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let valid: Set<URL>
    private var inspectedStorage: [URL] = []

    init(valid: Set<URL>) {
        self.valid = valid
    }

    var inspected: [URL] {
        lock.withLock { inspectedStorage }
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        lock.withLock { inspectedStorage.append(url) }
        return valid.contains(url)
    }

    func identity(at url: URL) -> CodexExecutableIdentity? {
        guard valid.contains(url) else { return nil }
        return CodexExecutableIdentity(
            device: 1,
            inode: 2,
            mode: 0o100700,
            size: 3,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )
    }
}

private final class FakeCodexVersionProber: CodexVersionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let output: String
    private var timeoutStorage: [Duration] = []

    init(output: String) {
        self.output = output
    }

    var timeouts: [Duration] {
        lock.withLock { timeoutStorage }
    }

    func version(of executable: URL, timeout: Duration) async throws -> String {
        _ = executable
        lock.withLock { timeoutStorage.append(timeout) }
        return output
    }
}

private struct ThrowingCodexVersionProber: CodexVersionProbing {
    func version(of executable: URL, timeout: Duration) async throws -> String {
        _ = executable
        _ = timeout
        throw CocoaError(.fileReadUnknown)
    }
}

private struct OverwritingCodexVersionProber: CodexVersionProbing {
    let replacementBody: String

    func version(of executable: URL, timeout: Duration) async throws -> String {
        _ = timeout
        let contents = "#!/bin/bash\nset -euo pipefail\n\(replacementBody)\n"
        try Data(contents.utf8).write(to: executable)
        return CodexExecutableLocator.pinnedVersion
    }
}

private struct IdentityFailingCodexExecutableInspector: CodexExecutableInspecting {
    let valid: URL

    func isExecutableRegularFile(at url: URL) -> Bool {
        url == valid
    }

    func identity(at url: URL) -> CodexExecutableIdentity? {
        _ = url
        return nil
    }
}

private final class SequencedIdentityCodexExecutableInspector:
    CodexExecutableInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let valid: URL
    private var identities: [CodexExecutableIdentity?]

    init(valid: URL, identities: [CodexExecutableIdentity?]) {
        self.valid = valid
        self.identities = identities
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        url == valid
    }

    func identity(at url: URL) -> CodexExecutableIdentity? {
        guard url == valid else { return nil }
        return lock.withLock {
            guard !identities.isEmpty else { return nil }
            return identities.removeFirst()
        }
    }
}

private enum IntegrationTimeoutError: Error {
    case timedOut
}

private func withIntegrationTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw IntegrationTimeoutError.timedOut
        }
        guard let first = try await group.next() else {
            throw IntegrationTimeoutError.timedOut
        }
        return first
    }
}

private func makeExecutableScript(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reborn-process-test-\(UUID().uuidString)")
    let contents = "#!/bin/sh\nset -eu\n\(body)\n"
    try Data(contents.utf8).write(to: url, options: .atomic)
    #if canImport(Darwin)
    guard chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    #endif
    return url
}

private let expectedPinnedSchemaFiles: Set<String> = [
    "JSONRPCMessage.json",
    "JSONRPCResponse.json",
    "JSONRPCError.json",
    "JSONRPCErrorError.json",
    "RequestId.json",
    "ClientRequest.json",
    "ClientNotification.json",
    "ServerNotification.json",
    "v1/InitializeParams.json",
    "v1/InitializeResponse.json",
    "v2/GetAccountRateLimitsResponse.json",
    "v2/AccountRateLimitsUpdatedNotification.json",
    "SHA256SUMS",
]

private func writeExecutableScript(_ body: String, to url: URL) throws {
    try Data("#!/bin/bash\nset -euo pipefail\n\(body)\n".utf8).write(to: url, options: .atomic)
    try makeExecutable(url)
}

private func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func runProcess(
    _ executable: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectory: URL? = nil
) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func directorySnapshot(_ root: URL) throws -> [String: Data] {
    let resolvedRootPath = root.resolvingSymlinksInPath().path
    let enumerator = try XCTUnwrap(
        FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
    )
    var snapshot: [String: Data] = [:]
    while let url = enumerator.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let resolvedPath = url.resolvingSymlinksInPath().path
        let relative = String(resolvedPath.dropFirst(resolvedRootPath.count + 1))
        snapshot[relative] = try Data(contentsOf: url)
    }
    return snapshot
}

#if canImport(Darwin)
private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private func assertProcessIsGone(
    _ pid: Int32,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    errno = 0
    XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
    XCTAssertEqual(errno, ESRCH, file: file, line: line)
}
#else
private func assertProcessIsGone(
    _ pid: Int32,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    _ = pid
    XCTFail("PID assertion is unavailable", file: file, line: line)
}
#endif

private func readPIDEventually(from url: URL) async throws -> Int32 {
    for _ in 0..<200 {
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8),
           let pid = Int32(text) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw IntegrationTimeoutError.timedOut
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
