import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol LineProcess: Sendable {
    var stdoutLines: AsyncThrowingStream<Data, Error> { get }
    var stderrLines: AsyncStream<Data> { get }
    var ownedChildProcessIdentifier: Int32? { get }
    func writeLine(_ data: Data) async throws
    func terminate(grace: Duration) async
}

public extension LineProcess {
    var ownedChildProcessIdentifier: Int32? { nil }
}

public protocol CodexProcessFactory: Sendable {
    func start(executable: URL) throws -> any LineProcess
}

public enum JSONRequestID: Hashable, Sendable {
    case number(Int64)
    case string(String)
}

extension JSONRequestID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else {
            return nil
        }
        return object[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int64
    public let message: String
    public let data: JSONValue?

    public init(code: Int64, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCEnvelope: Equatable, Sendable {
    public let id: JSONRequestID?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCErrorObject?
    public let hasParams: Bool
    public let hasResult: Bool

    fileprivate var isResponse: Bool {
        method == nil && id != nil && (hasResult || error != nil)
    }
}

extension JSONRPCEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(JSONRequestID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        hasParams = container.contains(.params)
        if hasParams {
            params = try container.decode(JSONValue.self, forKey: .params)
        } else {
            params = nil
        }
        hasResult = container.contains(.result)
        if hasResult {
            result = try container.decode(JSONValue.self, forKey: .result)
        } else {
            result = nil
        }
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
    }
}

public enum JSONLineTransportError: Error, Equatable, Sendable {
    case malformedJSON
    case lineTooLong(maximumBytes: Int)
    case endOfFile
    case unexpectedResponseID(JSONRequestID)
    case duplicateResponseID(JSONRequestID)
    case concurrentRead
    case stdoutBackpressureExceeded(maximumBufferedFrames: Int)
    case closed
}

private final class StdoutIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    init(stream: AsyncThrowingStream<Data, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

public actor JSONLineTransport {
    public static let defaultMaximumLineBytes = 1_048_576
    public static let completedResponseReplayCapacity = 256

    private let process: any LineProcess
    private let maximumLineBytes: Int
    private let iterator: StdoutIteratorBox
    private var pendingResponseIDs: Set<JSONRequestID> = []
    private var completedResponseIDs: Set<JSONRequestID> = []
    private var completedResponseIDOrder: [JSONRequestID] = []
    private var isReading = false
    private var isClosed = false

    public init(
        process: any LineProcess,
        maximumLineBytes: Int = JSONLineTransport.defaultMaximumLineBytes
    ) {
        self.process = process
        self.maximumLineBytes = maximumLineBytes
        iterator = StdoutIteratorBox(stream: process.stdoutLines)
    }

    public func sendRequest(
        id: JSONRequestID,
        method: String,
        params: JSONValue
    ) async throws {
        guard !isClosed else {
            throw JSONLineTransportError.closed
        }
        let data = try JSONEncoder().encode(
            JSONRequestEnvelope(id: id, method: method, params: params)
        )
        pendingResponseIDs.insert(id)
        do {
            try await process.writeLine(data)
        } catch {
            pendingResponseIDs.remove(id)
            throw error
        }
    }

    public func sendNotification(method: String, params: JSONValue? = nil) async throws {
        guard !isClosed else {
            throw JSONLineTransportError.closed
        }
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params {
            object["params"] = params
        }
        try await process.writeLine(JSONEncoder().encode(JSONValue.object(object)))
    }

    public func nextEvent() async throws -> JSONRPCEnvelope {
        guard !isClosed else {
            throw JSONLineTransportError.closed
        }
        guard !isReading else {
            throw JSONLineTransportError.concurrentRead
        }
        isReading = true
        defer { isReading = false }
        guard let line = try await iterator.next() else {
            throw JSONLineTransportError.endOfFile
        }
        guard line.count <= maximumLineBytes else {
            throw JSONLineTransportError.lineTooLong(maximumBytes: maximumLineBytes)
        }

        let envelope: JSONRPCEnvelope
        do {
            envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: line)
        } catch {
            throw JSONLineTransportError.malformedJSON
        }

        if envelope.isResponse, let id = envelope.id {
            if completedResponseIDs.contains(id) {
                throw JSONLineTransportError.duplicateResponseID(id)
            }
            guard pendingResponseIDs.remove(id) != nil else {
                throw JSONLineTransportError.unexpectedResponseID(id)
            }
            completedResponseIDs.insert(id)
            completedResponseIDOrder.append(id)
            if completedResponseIDOrder.count > Self.completedResponseReplayCapacity {
                let evicted = completedResponseIDOrder.removeFirst()
                completedResponseIDs.remove(evicted)
            }
        }
        return envelope
    }

    public func close(grace: Duration) async {
        guard !isClosed else {
            return
        }
        isClosed = true
        await process.terminate(grace: grace)
    }
}

private struct JSONRequestEnvelope: Encodable {
    let id: JSONRequestID
    let method: String
    let params: JSONValue
}

final class BoundedDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ data: Data) {
        lock.withLock {
            bytes.append(data)
            if bytes.count > maximumBytes {
                bytes.removeFirst(bytes.count - maximumBytes)
            }
        }
    }

    var byteCount: Int {
        lock.withLock { bytes.count }
    }

    var snapshot: Data {
        lock.withLock { bytes }
    }
}

private final class NewlineFramer: @unchecked Sendable {
    struct Output {
        let lines: [Data]
        let oversized: Bool
        let exceededFrameBudget: Bool
    }

    private let lock = NSLock()
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    func append(_ chunk: Data, maximumLines: Int) -> Output {
        lock.withLock {
            var lines: [Data] = []
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                guard lines.count < maximumLines else {
                    buffer.removeAll(keepingCapacity: false)
                    return Output(
                        lines: lines,
                        oversized: false,
                        exceededFrameBudget: true
                    )
                }
                let segment = chunk[start..<newline]
                guard buffer.count + segment.count <= maximumLineBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    return Output(
                        lines: lines,
                        oversized: true,
                        exceededFrameBudget: false
                    )
                }
                buffer.append(contentsOf: segment)
                var line = buffer
                if line.last == 0x0D {
                    line.removeLast()
                }
                lines.append(line)
                buffer.removeAll(keepingCapacity: true)
                start = chunk.index(after: newline)
            }
            let remainder = chunk[start...]
            guard buffer.count + remainder.count <= maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                return Output(
                    lines: lines,
                    oversized: true,
                    exceededFrameBudget: false
                )
            }
            buffer.append(contentsOf: remainder)
            return Output(
                lines: lines,
                oversized: false,
                exceededFrameBudget: false
            )
        }
    }

    func finish() -> Data? {
        lock.withLock {
            guard !buffer.isEmpty else {
                return nil
            }
            let final = buffer
            buffer.removeAll(keepingCapacity: false)
            return final
        }
    }
}

protocol FoundationLineProcessDiagnostics: Sendable {
    var retainedDiagnosticByteCount: Int { get }
    var maximumRetainedStderrStreamBytes: Int { get }
    var ownedProcessIdentifier: Int32 { get }
}

private final class WeakProcessBox: @unchecked Sendable {
    weak var process: Process?

    init(_ process: Process) {
        self.process = process
    }
}

public struct FoundationCodexProcessFactory: CodexProcessFactory {
    public static let appServerArguments = ["app-server", "--stdio"]

    public init() {}

    public func start(executable: URL) throws -> any LineProcess {
        try FoundationLineProcess(
            executable: executable,
            arguments: Self.appServerArguments
        )
    }
}

private final class FoundationLineProcess:
    LineProcess,
    FoundationLineProcessDiagnostics,
    @unchecked Sendable
{
    private static let stderrChunkBytes = 4 * 1_024
    private static let stderrBufferedChunks = 16
    private static let stdoutBufferedFrames = 8

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation
    private let diagnosticBuffer = BoundedDiagnosticBuffer(maximumBytes: 64 * 1_024)
    private let lock = NSLock()
    private var terminated = false

    let stdoutLines: AsyncThrowingStream<Data, Error>
    let stderrLines: AsyncStream<Data>

    var retainedDiagnosticByteCount: Int {
        diagnosticBuffer.byteCount
    }

    var maximumRetainedStderrStreamBytes: Int {
        Self.stderrChunkBytes * Self.stderrBufferedChunks
    }

    var ownedProcessIdentifier: Int32 {
        process.processIdentifier
    }

    var ownedChildProcessIdentifier: Int32? {
        process.processIdentifier
    }

    init(executable: URL, arguments: [String]) throws {
        let stdoutPair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.stdoutBufferedFrames)
        )
        stdoutLines = stdoutPair.stream
        stdoutContinuation = stdoutPair.continuation
        let stderrPair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.stderrBufferedChunks)
        )
        stderrLines = stderrPair.stream
        stderrContinuation = stderrPair.continuation

        let process = Process()
        self.process = process
        process.executableURL = executable
        process.arguments = arguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        stdinHandle = inputPipe.fileHandleForWriting
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let processBox = WeakProcessBox(process)
        let stdoutFramer = NewlineFramer(
            maximumLineBytes: JSONLineTransport.defaultMaximumLineBytes
        )
        outputPipe.fileHandleForReading.readabilityHandler = {
            [processBox, stdoutContinuation, stdoutFramer] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                if let final = stdoutFramer.finish() {
                    if case .dropped = stdoutContinuation.yield(final) {
                        stdoutContinuation.finish(
                            throwing: JSONLineTransportError.stdoutBackpressureExceeded(
                                maximumBufferedFrames: Self.stdoutBufferedFrames
                            )
                        )
                        handle.readabilityHandler = nil
                        processBox.process?.terminate()
                        return
                    }
                }
                stdoutContinuation.finish()
                handle.readabilityHandler = nil
                return
            }
            let output = stdoutFramer.append(
                chunk,
                maximumLines: Self.stdoutBufferedFrames
            )
            for line in output.lines {
                switch stdoutContinuation.yield(line) {
                case .enqueued:
                    continue
                case .dropped:
                    stdoutContinuation.finish(
                        throwing: JSONLineTransportError.stdoutBackpressureExceeded(
                            maximumBufferedFrames: Self.stdoutBufferedFrames
                        )
                    )
                    handle.readabilityHandler = nil
                    processBox.process?.terminate()
                    return
                case .terminated:
                    handle.readabilityHandler = nil
                    return
                @unknown default:
                    handle.readabilityHandler = nil
                    return
                }
            }
            if output.exceededFrameBudget {
                stdoutContinuation.finish(
                    throwing: JSONLineTransportError.stdoutBackpressureExceeded(
                        maximumBufferedFrames: Self.stdoutBufferedFrames
                    )
                )
                handle.readabilityHandler = nil
                processBox.process?.terminate()
                return
            }
            if output.oversized {
                stdoutContinuation.finish(
                    throwing: JSONLineTransportError.lineTooLong(
                        maximumBytes: JSONLineTransport.defaultMaximumLineBytes
                    )
                )
                handle.readabilityHandler = nil
                processBox.process?.terminate()
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = {
            [diagnosticBuffer, stderrContinuation] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                stderrContinuation.finish()
                handle.readabilityHandler = nil
                return
            }
            diagnosticBuffer.append(chunk)
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = min(start + Self.stderrChunkBytes, chunk.endIndex)
                stderrContinuation.yield(Data(chunk[start..<end]))
                start = end
            }
        }

        do {
            try process.run()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            stdoutContinuation.finish()
            stderrContinuation.finish()
            for handle in [
                inputPipe.fileHandleForReading,
                inputPipe.fileHandleForWriting,
                outputPipe.fileHandleForReading,
                outputPipe.fileHandleForWriting,
                errorPipe.fileHandleForReading,
                errorPipe.fileHandleForWriting,
            ] {
                try? handle.close()
            }
            process.standardInput = nil
            process.standardOutput = nil
            process.standardError = nil
            throw error
        }
    }

    func writeLine(_ data: Data) async throws {
        guard !lock.withLock({ terminated }) else {
            throw JSONLineTransportError.closed
        }
        var framed = data
        framed.append(0x0A)
        try stdinHandle.write(contentsOf: framed)
    }

    func terminate(grace: Duration) async {
        let shouldTerminate = lock.withLock { () -> Bool in
            if terminated { return false }
            terminated = true
            return true
        }
        guard shouldTerminate else {
            return
        }

        try? stdinHandle.close()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        let termReserve = min(grace, .milliseconds(400))
        let killReserve = min(grace, .milliseconds(100))
        let termAt = deadline.advanced(by: .zero - termReserve)
        let killAt = deadline.advanced(by: .zero - killReserve)

        while process.isRunning, clock.now < termAt {
            try? await clock.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
            while process.isRunning, clock.now < killAt {
                try? await clock.sleep(for: .milliseconds(20))
            }
        }
        #if canImport(Darwin)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        #endif
        while process.isRunning, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        if process.isRunning {
            #if canImport(Darwin)
            kill(process.processIdentifier, SIGKILL)
            #endif
        }
        process.waitUntilExit()
    }
}
