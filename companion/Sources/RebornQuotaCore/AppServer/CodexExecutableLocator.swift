import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol CodexExecutableInspecting: Sendable {
    func isExecutableRegularFile(at url: URL) -> Bool
    func identity(at url: URL) -> CodexExecutableIdentity?
}

public protocol CodexVersionProbing: Sendable {
    func version(of executable: URL, timeout: Duration) async throws -> String
}

public enum CodexExecutableLocatorError: Error, Equatable, Sendable {
    case configuredPathMustBeAbsolute
    case configuredPathInvalid
    case configuredVersionProbeFailed
    case executableIdentityUnavailable
    case executableChangedDuringVersionProbe
    case unavailable
    case versionProbeFailed
}

public struct CodexExecutableIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let statusChangeSeconds: Int64
    public let statusChangeNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        size: UInt64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        statusChangeSeconds: Int64,
        statusChangeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }

    static func capture(at url: URL) -> Self? {
        #if canImport(Darwin)
        var metadata = stat()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return nil
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            return nil
        }
        guard metadata.st_size >= 0 else {
            return nil
        }
        return Self(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            mode: UInt32(metadata.st_mode),
            size: UInt64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
        #else
        _ = url
        return nil
        #endif
    }
}

public struct LocatedCodexExecutable: Equatable, Sendable {
    public let url: URL
    public let reportedVersion: String
    public let matchesPinnedVersion: Bool
    public let identity: CodexExecutableIdentity

    init(
        url: URL,
        reportedVersion: String,
        matchesPinnedVersion: Bool,
        identity: CodexExecutableIdentity
    ) {
        self.url = url
        self.reportedVersion = reportedVersion
        self.matchesPinnedVersion = matchesPinnedVersion
        self.identity = identity
    }
}

public struct CodexExecutableLocator: Sendable {
    public static let pinnedVersion = "codex-cli 0.144.0-alpha.4"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let allowDevelopmentPATH: Bool
    private let inspector: any CodexExecutableInspecting
    private let versionProber: any CodexVersionProbing

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowDevelopmentPATH: Bool = false,
        inspector: any CodexExecutableInspecting = FoundationCodexExecutableInspector(),
        versionProber: any CodexVersionProbing = FoundationCodexVersionProber()
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.allowDevelopmentPATH = allowDevelopmentPATH
        self.inspector = inspector
        self.versionProber = versionProber
    }

    public func locate() async throws -> LocatedCodexExecutable {
        if let configured = environment["CODEX_CLI_PATH"] {
            guard !configured.isEmpty, configured.hasPrefix("/") else {
                throw CodexExecutableLocatorError.configuredPathMustBeAbsolute
            }
            let executable = URL(fileURLWithPath: configured)
            guard inspector.isExecutableRegularFile(at: executable) else {
                throw CodexExecutableLocatorError.configuredPathInvalid
            }
            do {
                return try await locatedExecutable(at: executable)
            } catch let error as CodexExecutableLocatorError
                where error == .executableIdentityUnavailable ||
                      error == .executableChangedDuringVersionProbe {
                throw error
            } catch {
                throw CodexExecutableLocatorError.configuredVersionProbeFailed
            }
        }

        let candidates = fallbackCandidateURLs()
        guard let executable = candidates.first(where: inspector.isExecutableRegularFile(at:)) else {
            throw CodexExecutableLocatorError.unavailable
        }

        do {
            return try await locatedExecutable(at: executable)
        } catch let error as CodexExecutableLocatorError
            where error == .executableIdentityUnavailable ||
                  error == .executableChangedDuringVersionProbe {
            throw error
        } catch {
            throw CodexExecutableLocatorError.versionProbeFailed
        }
    }

    private func locatedExecutable(at executable: URL) async throws -> LocatedCodexExecutable {
        guard let identityBeforeProbe = inspector.identity(at: executable) else {
            throw CodexExecutableLocatorError.executableIdentityUnavailable
        }
        let version = try await versionProber.version(of: executable, timeout: .seconds(2))
        guard let identityAfterProbe = inspector.identity(at: executable) else {
            throw CodexExecutableLocatorError.executableIdentityUnavailable
        }
        guard identityBeforeProbe == identityAfterProbe else {
            throw CodexExecutableLocatorError.executableChangedDuringVersionProbe
        }
        return LocatedCodexExecutable(
            url: executable,
            reportedVersion: version,
            matchesPinnedVersion: version == Self.pinnedVersion,
            identity: identityAfterProbe
        )
    }

    private func fallbackCandidateURLs() -> [URL] {
        var candidates: [URL] = []
        candidates.append(
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        )
        candidates.append(
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
        )
        if allowDevelopmentPATH, let path = environment["PATH"] {
            candidates.append(
                contentsOf: path.split(separator: ":").map {
                    URL(fileURLWithPath: String($0)).appendingPathComponent("codex")
                }
            )
        }
        return candidates
    }
}

public struct FoundationCodexExecutableInspector: CodexExecutableInspecting {
    public init() {}

    public func isExecutableRegularFile(at url: URL) -> Bool {
        guard url.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    public func identity(at url: URL) -> CodexExecutableIdentity? {
        CodexExecutableIdentity.capture(at: url)
    }
}

public struct FoundationCodexVersionProber: CodexVersionProbing {
    public init() {}

    public func version(of executable: URL, timeout: Duration) async throws -> String {
        let runner = BoundedVersionProbeProcess(executable: executable, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await runner.run()
        } onCancel: {
            runner.requestCancellation()
        }
    }
}

private struct DrainedProbeBytes: Sendable {
    let data: Data
    let exceededCapacity: Bool
}

private final class BoundedVersionProbeProcess: @unchecked Sendable {
    private static let maximumStreamBytes = 64 * 1_024

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let timeout: Duration
    private let lock = NSLock()
    private var launched = false

    init(executable: URL, timeout: Duration) {
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func requestCancellation() {
        lock.withLock {
            guard launched, process.isRunning else { return }
            process.terminate()
        }
    }

    func run() async throws -> String {
        let clock = ContinuousClock()
        let totalDeadline = clock.now.advanced(by: timeout)
        let shutdownReserve = min(timeout, .milliseconds(200))
        let runDeadline = totalDeadline.advanced(by: .zero - shutdownReserve)
        do {
            try process.run()
            lock.withLock { launched = true }
        } catch {
            closeEveryPipeEnd()
            throw CodexExecutableLocatorError.versionProbeFailed
        }

        do {
            try Task.checkCancellation()
        } catch {
            await stopAndReap(deadline: totalDeadline)
            closeEveryPipeHandle()
            throw CancellationError()
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let stdoutTask = Self.drain(stdoutPipe.fileHandleForReading)
        let stderrTask = Self.drain(stderrPipe.fileHandleForReading)

        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < runDeadline else {
                    throw CodexExecutableLocatorError.versionProbeFailed
                }
                try await clock.sleep(for: .milliseconds(10))
            }
            process.waitUntilExit()
            let stdout = await stdoutTask.value
            _ = await stderrTask.value
            closeReadEnds()

            guard process.terminationStatus == 0,
                  !stdout.exceededCapacity,
                  let string = String(data: stdout.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                throw CodexExecutableLocatorError.versionProbeFailed
            }
            try Task.checkCancellation()
            return string
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            await stopAndReap(deadline: totalDeadline)
            closeReadEnds()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            if wasCancelled {
                throw CancellationError()
            }
            throw CodexExecutableLocatorError.versionProbeFailed
        }
    }

    private static func drain(
        _ handle: FileHandle
    ) -> Task<DrainedProbeBytes, Never> {
        Task.detached(priority: .utility) {
            var retained = Data()
            var exceededCapacity = false
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 4 * 1_024),
                          !chunk.isEmpty else {
                        break
                    }
                    let remaining = maximumStreamBytes - retained.count
                    if remaining > 0 {
                        retained.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining {
                        exceededCapacity = true
                    }
                } catch {
                    break
                }
            }
            return DrainedProbeBytes(data: retained, exceededCapacity: exceededCapacity)
        }
    }

    private func stopAndReap(deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        if process.isRunning {
            process.terminate()
        }
        let killReserve = min(timeout, .milliseconds(50))
        let killAt = deadline.advanced(by: .zero - killReserve)
        while process.isRunning, !Task.isCancelled, clock.now < killAt {
            try? await clock.sleep(for: .milliseconds(5))
        }
        #if canImport(Darwin)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        #endif
        while process.isRunning, clock.now < deadline {
            if Task.isCancelled {
                await Task.yield()
            } else {
                try? await clock.sleep(for: .milliseconds(5))
            }
        }
        #if canImport(Darwin)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        #endif
        process.waitUntilExit()
    }

    private func closeReadEnds() {
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    private func closeEveryPipeEnd() {
        closeEveryPipeHandle()
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
    }

    private func closeEveryPipeHandle() {
        for handle in [
            stdoutPipe.fileHandleForReading,
            stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading,
            stderrPipe.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }
}
