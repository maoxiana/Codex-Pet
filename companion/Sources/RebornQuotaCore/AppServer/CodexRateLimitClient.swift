import Foundation

public protocol AppServerScheduler: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemAppServerScheduler: AppServerScheduler {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

public enum CodexRateLimitStage: Equatable, Sendable {
    case initialize
    case read
}

public enum CodexRateLimitClientError: Error, Equatable, Sendable {
    case alreadyRunning
    case authenticationRequired
    case cancelled
    case executableChanged
    case incompatibleProtocol
    case responseError(code: Int64)
    case timeout(CodexRateLimitStage)
    case transportFailure
    case transport(JSONLineTransportError)
}

public struct CodexRateLimitClientConfiguration: Equatable, Sendable {
    public var initializeTimeout: Duration
    public var readTimeout: Duration
    public var safetyRefreshInterval: Duration
    public var shutdownGrace: Duration

    public init(
        initializeTimeout: Duration = .seconds(5),
        readTimeout: Duration = .seconds(8),
        safetyRefreshInterval: Duration = .seconds(60),
        shutdownGrace: Duration = .seconds(2)
    ) {
        self.initializeTimeout = initializeTimeout
        self.readTimeout = readTimeout
        self.safetyRefreshInterval = safetyRefreshInterval
        self.shutdownGrace = shutdownGrace
    }
}

public struct CodexRateLimitProbeOutput: Encodable, Equatable, Sendable {
    public let status: String
    public let limitId: String?
    public let durationMins: Int?
    public let remainingPercent: Int?
    public let hasResetTime: Bool

    public static let unavailable = CodexRateLimitProbeOutput(
        status: "unavailable",
        limitId: nil,
        durationMins: nil,
        remainingPercent: nil,
        hasResetTime: false
    )

    public init(extraction: WeeklyQuotaExtraction) {
        guard let quota = extraction.quota else {
            self.init(
                status: "noWeeklyWindow",
                limitId: nil,
                durationMins: nil,
                remainingPercent: nil,
                hasResetTime: false
            )
            return
        }
        self.init(
            status: "available",
            limitId: "codex",
            durationMins: 10_080,
            remainingPercent: min(max(quota.remainingPercent, 0), 100),
            hasResetTime: quota.resetsAt != nil
        )
    }

    private init(
        status: String,
        limitId: String?,
        durationMins: Int?,
        remainingPercent: Int?,
        hasResetTime: Bool
    ) {
        self.status = status
        self.limitId = limitId
        self.durationMins = durationMins
        self.remainingPercent = remainingPercent
        self.hasResetTime = hasResetTime
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case limitId
        case durationMins
        case remainingPercent
        case hasResetTime
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let limitId {
            try container.encode(limitId, forKey: .limitId)
        } else {
            try container.encodeNil(forKey: .limitId)
        }
        if let durationMins {
            try container.encode(durationMins, forKey: .durationMins)
        } else {
            try container.encodeNil(forKey: .durationMins)
        }
        if let remainingPercent {
            try container.encode(remainingPercent, forKey: .remainingPercent)
        } else {
            try container.encodeNil(forKey: .remainingPercent)
        }
        try container.encode(hasResetTime, forKey: .hasResetTime)
    }
}

public enum CodexProtocolWarning: Equatable, Sendable {
    case runtimeVersionMismatch

    public var diagnosticMessage: String {
        switch self {
        case .runtimeVersionMismatch:
            return "warning: Codex CLI version differs from the pinned quota protocol; attempting compatible initialization"
        }
    }
}

public protocol CodexWarningSink: Sendable {
    func emit(_ warning: CodexProtocolWarning)
}

public struct StandardErrorCodexWarningSink: CodexWarningSink {
    public init() {}

    public func emit(_ warning: CodexProtocolWarning) {
        var data = Data(warning.diagnosticMessage.utf8)
        data.append(0x0A)
        FileHandle.standardError.write(data)
    }
}

/// Reconnection delays are intentionally conservative after the fourth
/// failure. A connection is considered healthy only after initialize and a
/// complete rate-limit snapshot both succeed; that event resets the sequence.
public struct CodexReconnectBackoff: Equatable, Sendable {
    private static let delays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(30),
    ]
    private var failureCount = 0

    public init() {}

    public mutating func delayAfterFailure() -> Duration {
        let delay = Self.delays[min(failureCount, Self.delays.count - 1)]
        failureCount += 1
        return delay
    }

    public mutating func markHealthyAfterSnapshot() {
        failureCount = 0
    }
}

public actor CodexRateLimitClient {
    private let processFactory: any CodexProcessFactory
    private let scheduler: any AppServerScheduler
    private let refreshMachine: QuotaRefreshMachine
    private let configuration: CodexRateLimitClientConfiguration
    private let warningSink: any CodexWarningSink
    private var isActive = false
    #if REBORN_QUOTA_QA
    private var qaActiveProcess: (any LineProcess)?
    private var qaConnectionEpoch: UInt64 = 0
    #endif

    public init(
        processFactory: any CodexProcessFactory = FoundationCodexProcessFactory(),
        scheduler: any AppServerScheduler = SystemAppServerScheduler(),
        refreshMachine: QuotaRefreshMachine = QuotaRefreshMachine(),
        configuration: CodexRateLimitClientConfiguration = CodexRateLimitClientConfiguration(),
        warningSink: any CodexWarningSink = StandardErrorCodexWarningSink()
    ) {
        self.processFactory = processFactory
        self.scheduler = scheduler
        self.refreshMachine = refreshMachine
        self.configuration = configuration
        self.warningSink = warningSink
    }

    public nonisolated var states: AsyncStream<QuotaDisplayState> {
        refreshMachine.subscribeStates()
    }

    public func fetchOnce(
        executable: LocatedCodexExecutable
    ) async throws -> WeeklyQuotaExtraction {
        warnIfNeeded(for: executable)
        return try await fetchOnce(
            executable: executable.url,
            expectedIdentity: executable.identity
        )
    }

    /// Dedicated one-shot operation used by the normalized probe. It exits
    /// after the first clean snapshot and never enters the production monitor.
    func fetchOnce(executable: URL) async throws -> WeeklyQuotaExtraction {
        try await fetchOnce(executable: executable, expectedIdentity: nil)
    }

    private func fetchOnce(
        executable: URL,
        expectedIdentity: CodexExecutableIdentity?
    ) async throws -> WeeklyQuotaExtraction {
        guard !isActive else {
            throw CodexRateLimitClientError.alreadyRunning
        }
        isActive = true

        do {
            try validateExecutableIdentity(expectedIdentity, at: executable)
        } catch {
            isActive = false
            throw error
        }

        let process: any LineProcess
        do {
            process = try processFactory.start(executable: executable)
        } catch {
            isActive = false
            throw CodexRateLimitClientError.transportFailure
        }
        let transport = JSONLineTransport(process: process)

        #if REBORN_QUOTA_QA
        qaConnectionEpoch &+= 1
        qaActiveProcess = process
        defer { qaActiveProcess = nil }
        #endif

        do {
            let session = try await performInitialRead(
                transport: transport,
                reason: .initial
            )
            await transport.close(grace: configuration.shutdownGrace)
            isActive = false
            return session.extraction
        } catch {
            await transport.close(grace: configuration.shutdownGrace)
            isActive = false
            throw normalize(error)
        }
    }

    /// Source-compatible one-shot spelling retained for callers built before
    /// the production monitor and probe operations were separated.
    func readOnce(executable: URL) async throws -> WeeklyQuotaExtraction {
        try await fetchOnce(executable: executable)
    }

    public func runUntilCancelled(executable: LocatedCodexExecutable) async throws {
        warnIfNeeded(for: executable)
        try await runUntilCancelled(
            executable: executable.url,
            expectedIdentity: executable.identity
        )
    }

    /// Production operation. It owns one child at a time, remains connected
    /// after a clean snapshot, and reconnects transient failures until the
    /// caller cancels it.
    func runUntilCancelled(executable: URL) async throws {
        try await runUntilCancelled(executable: executable, expectedIdentity: nil)
    }

    private func runUntilCancelled(
        executable: URL,
        expectedIdentity: CodexExecutableIdentity?
    ) async throws {
        guard !isActive else {
            throw CodexRateLimitClientError.alreadyRunning
        }
        isActive = true
        do {
            try await runProductionLoop(
                executable: executable,
                expectedIdentity: expectedIdentity
            )
            isActive = false
        } catch {
            isActive = false
            throw normalize(error)
        }
    }

    private struct InitialSession: Sendable {
        let extraction: WeeklyQuotaExtraction
        let nextRequestID: Int64
    }

    private enum SessionSignal: Sendable {
        case event(JSONRPCEnvelope)
        case safetyRefresh
        case readTimeout(JSONRequestID)
    }

    private func runProductionLoop(
        executable: URL,
        expectedIdentity: CodexExecutableIdentity?
    ) async throws {
        var reason = RefreshReason.initial
        var backoff = CodexReconnectBackoff()

        while true {
            try Task.checkCancellation()
            try validateExecutableIdentity(expectedIdentity, at: executable)

            let process: (any LineProcess)?
            do {
                process = try processFactory.start(executable: executable)
            } catch {
                process = nil
            }

            guard let process else {
                try await sleepBeforeReconnect(backoff.delayAfterFailure())
                reason = .reconnection
                continue
            }

            let transport = JSONLineTransport(process: process)
            #if REBORN_QUOTA_QA
            qaConnectionEpoch &+= 1
            qaActiveProcess = process
            #endif
            do {
                let session = try await performInitialRead(
                    transport: transport,
                    reason: reason
                )
                backoff.markHealthyAfterSnapshot()
                try await monitorConnection(
                    transport: transport,
                    nextRequestID: session.nextRequestID
                )
                throw CodexRateLimitClientError.transportFailure
            } catch {
                await transport.close(grace: configuration.shutdownGrace)
                #if REBORN_QUOTA_QA
                qaActiveProcess = nil
                #endif
                let clientError = normalize(error)
                if isTerminal(clientError) {
                    throw clientError
                }
                try await sleepBeforeReconnect(backoff.delayAfterFailure())
                reason = .reconnection
            }
        }
    }

    #if REBORN_QUOTA_QA
    public struct QAChildSnapshot: Codable, Equatable, Sendable {
        public let processIdentifier: Int32?
        public let connectionEpoch: UInt64

        public init(processIdentifier: Int32?, connectionEpoch: UInt64) {
            self.processIdentifier = processIdentifier
            self.connectionEpoch = connectionEpoch
        }
    }

    public func qaChildSnapshot() -> QAChildSnapshot {
        QAChildSnapshot(
            processIdentifier: qaActiveProcess?.ownedChildProcessIdentifier,
            connectionEpoch: qaConnectionEpoch
        )
    }

    /// Terminates only the process returned by this client's process factory.
    /// The production reconnect loop is responsible for starting its successor.
    public func qaRestartOwnedChild() async -> QAChildSnapshot {
        let before = qaChildSnapshot()
        await qaActiveProcess?.terminate(grace: configuration.shutdownGrace)
        return before
    }
    #endif

    private func performInitialRead(
        transport: JSONLineTransport,
        reason: RefreshReason
    ) async throws -> InitialSession {
        _ = await refreshMachine.connectionStarted()
        guard var token = await refreshMachine.invalidate(reason) else {
            throw CodexRateLimitClientError.transportFailure
        }

        try await transport.sendRequest(
            id: .number(1),
            method: "initialize",
            params: Self.initializeParams
        )
        let initialize = try await response(
            id: .number(1),
            stage: .initialize,
            timeout: configuration.initializeTimeout,
            transport: transport
        )
        try validateInitialize(initialize)

        try await transport.sendNotification(method: "initialized")

        var nextID: Int64 = 2
        while true {
            let requestID = JSONRequestID.number(nextID)
            try await transport.sendRequest(
                id: requestID,
                method: "account/rateLimits/read",
                params: .null
            )
            let envelope = try await response(
                id: requestID,
                stage: .read,
                timeout: configuration.readTimeout,
                transport: transport
            )
            let extraction: WeeklyQuotaExtraction
            do {
                extraction = try decodeExtraction(from: envelope)
            } catch {
                _ = await refreshMachine.complete(token, result: .failure(error))
                throw error
            }
            guard let followUp = await refreshMachine.complete(
                token,
                result: .success(extraction)
            ) else {
                return InitialSession(
                    extraction: extraction,
                    nextRequestID: nextID + 1
                )
            }
            token = followUp
            nextID += 1
        }
    }

    private func monitorConnection(
        transport: JSONLineTransport,
        nextRequestID initialRequestID: Int64
    ) async throws {
        try await withThrowingTaskGroup(of: SessionSignal.self) { group in
            defer { group.cancelAll() }
            var nextRequestID = initialRequestID
            var pending: [JSONRequestID: ReadToken] = [:]

            group.addTask {
                .event(try await transport.nextEvent())
            }
            group.addTask { [scheduler, configuration] in
                try await scheduler.sleep(for: configuration.safetyRefreshInterval)
                return .safetyRefresh
            }

            while let signal = try await group.next() {
                try Task.checkCancellation()
                switch signal {
                case .event(let event):
                    group.addTask {
                        .event(try await transport.nextEvent())
                    }

                    if event.method == "account/rateLimits/updated" {
                        if let token = await refreshMachine.invalidate(.notification) {
                            let id = try await sendMonitoringRead(
                                token: token,
                                nextRequestID: &nextRequestID,
                                pending: &pending,
                                transport: transport
                            )
                            group.addTask { [scheduler, configuration] in
                                try await scheduler.sleep(for: configuration.readTimeout)
                                return .readTimeout(id)
                            }
                        }
                        continue
                    }
                    if event.method != nil {
                        continue
                    }
                    guard let id = event.id,
                          let token = pending.removeValue(forKey: id) else {
                        throw CodexRateLimitClientError.incompatibleProtocol
                    }

                    let extraction: WeeklyQuotaExtraction
                    do {
                        extraction = try decodeExtraction(from: event)
                    } catch {
                        _ = await refreshMachine.complete(token, result: .failure(error))
                        throw error
                    }
                    if let followUp = await refreshMachine.complete(
                        token,
                        result: .success(extraction)
                    ) {
                        let followUpID = try await sendMonitoringRead(
                            token: followUp,
                            nextRequestID: &nextRequestID,
                            pending: &pending,
                            transport: transport
                        )
                        group.addTask { [scheduler, configuration] in
                            try await scheduler.sleep(for: configuration.readTimeout)
                            return .readTimeout(followUpID)
                        }
                    }

                case .safetyRefresh:
                    group.addTask { [scheduler, configuration] in
                        try await scheduler.sleep(for: configuration.safetyRefreshInterval)
                        return .safetyRefresh
                    }
                    if let token = await refreshMachine.invalidate(.scheduled) {
                        let id = try await sendMonitoringRead(
                            token: token,
                            nextRequestID: &nextRequestID,
                            pending: &pending,
                            transport: transport
                        )
                        group.addTask { [scheduler, configuration] in
                            try await scheduler.sleep(for: configuration.readTimeout)
                            return .readTimeout(id)
                        }
                    }

                case .readTimeout(let id):
                    if pending[id] != nil {
                        throw CodexRateLimitClientError.timeout(.read)
                    }
                }
            }
        }
    }

    private func sendMonitoringRead(
        token: ReadToken,
        nextRequestID: inout Int64,
        pending: inout [JSONRequestID: ReadToken],
        transport: JSONLineTransport
    ) async throws -> JSONRequestID {
        let id = JSONRequestID.number(nextRequestID)
        nextRequestID += 1
        try await transport.sendRequest(
            id: id,
            method: "account/rateLimits/read",
            params: .null
        )
        pending[id] = token
        return id
    }

    private func sleepBeforeReconnect(_ delay: Duration) async throws {
        do {
            try await scheduler.sleep(for: delay)
        } catch {
            throw normalize(error)
        }
    }

    private func isTerminal(_ error: CodexRateLimitClientError) -> Bool {
        switch error {
        case .alreadyRunning, .authenticationRequired, .cancelled, .executableChanged,
             .incompatibleProtocol:
            return true
        case .responseError, .timeout, .transportFailure, .transport:
            return false
        }
    }

    private func warnIfNeeded(for executable: LocatedCodexExecutable) {
        if !executable.matchesPinnedVersion {
            warningSink.emit(.runtimeVersionMismatch)
        }
    }

    private func validateExecutableIdentity(
        _ expectedIdentity: CodexExecutableIdentity?,
        at executable: URL
    ) throws {
        guard let expectedIdentity else {
            return
        }
        guard CodexExecutableIdentity.capture(at: executable) == expectedIdentity else {
            throw CodexRateLimitClientError.executableChanged
        }
    }

    private func response(
        id: JSONRequestID,
        stage: CodexRateLimitStage,
        timeout: Duration,
        transport: JSONLineTransport
    ) async throws -> JSONRPCEnvelope {
        try await withThrowingTaskGroup(of: JSONRPCEnvelope.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await self.readUntilResponse(id: id, transport: transport)
            }
            group.addTask { [scheduler] in
                try await scheduler.sleep(for: timeout)
                throw CodexRateLimitClientError.timeout(stage)
            }
            guard let first = try await group.next() else {
                throw CodexRateLimitClientError.transportFailure
            }
            return first
        }
    }

    private func readUntilResponse(
        id: JSONRequestID,
        transport: JSONLineTransport
    ) async throws -> JSONRPCEnvelope {
        while true {
            let event = try await transport.nextEvent()
            if event.method == "account/rateLimits/updated" {
                // The update is deliberately only an invalidation. Its sparse
                // payload is never merged into the authoritative read result.
                _ = await refreshMachine.invalidate(.notification)
                continue
            }
            if event.method != nil {
                continue
            }
            if event.id == id {
                return event
            }
        }
    }

    private func validateInitialize(_ envelope: JSONRPCEnvelope) throws {
        if let error = envelope.error {
            if normalizedResponseError(error) == .authenticationRequired {
                throw CodexRateLimitClientError.authenticationRequired
            }
            throw CodexRateLimitClientError.incompatibleProtocol
        }
        guard envelope.hasResult,
              case .object(let object) = envelope.result,
              case .string(let codexHome) = object["codexHome"],
              codexHome.hasPrefix("/"),
              case .string = object["platformFamily"],
              case .string = object["platformOs"],
              case .string = object["userAgent"] else {
            throw CodexRateLimitClientError.incompatibleProtocol
        }
    }

    private func decodeExtraction(from envelope: JSONRPCEnvelope) throws -> WeeklyQuotaExtraction {
        if let error = envelope.error {
            throw normalizedResponseError(error)
        }
        guard envelope.hasResult,
              case .object = envelope.result,
              let result = envelope.result else {
            throw CodexRateLimitClientError.incompatibleProtocol
        }
        do {
            let data = try JSONEncoder().encode(result)
            let response = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: data)
            return WeeklyQuotaExtractor.extract(from: response)
        } catch let error as CodexRateLimitClientError {
            throw error
        } catch {
            throw CodexRateLimitClientError.incompatibleProtocol
        }
    }

    private func normalizedResponseError(_ error: JSONRPCErrorObject) -> CodexRateLimitClientError {
        let lowercased = error.message.lowercased()
        if lowercased.contains("auth") ||
            lowercased.contains("login") ||
            lowercased.contains("token") ||
            lowercased.contains("credential") {
            return .authenticationRequired
        }
        if error.code == -32601 || error.code == -32602 {
            return .incompatibleProtocol
        }
        return .responseError(code: error.code)
    }

    private func normalize(_ error: Error) -> CodexRateLimitClientError {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let clientError = error as? CodexRateLimitClientError {
            return clientError
        }
        if let transportError = error as? JSONLineTransportError {
            return .transport(transportError)
        }
        return .transportFailure
    }

    private static let initializeParams: JSONValue = .object([
        "clientInfo": .object([
            "name": .string("reborn-quota"),
            "title": .string("Reborn Quota"),
            "version": .string("0.1.0"),
        ]),
        "capabilities": .object([
            "experimentalApi": .bool(true),
        ]),
    ])
}
