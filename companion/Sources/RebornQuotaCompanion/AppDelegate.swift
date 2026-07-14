import AppKit
import Foundation
import RebornQuotaCore

#if REBORN_QUOTA_QA
struct QAControlOptions: Sendable {
    let restartChildAfter: Duration
    let reportURL: URL

    static func parse(_ arguments: [String]) -> QAControlOptions? {
        guard let secondsIndex = arguments.firstIndex(of: "--qa-restart-child-after"),
              arguments.indices.contains(secondsIndex + 1),
              let seconds = QAControlArgumentPolicy.restartDelaySeconds(
                  arguments[secondsIndex + 1]
              ),
              let reportIndex = arguments.firstIndex(of: "--qa-report"),
              arguments.indices.contains(reportIndex + 1) else {
            return nil
        }
        let path = arguments[reportIndex + 1]
        guard path.hasPrefix("/") else { return nil }
        return QAControlOptions(
            restartChildAfter: .milliseconds(Int64(seconds * 1_000)),
            reportURL: URL(fileURLWithPath: path)
        )
    }
}

private struct QAChildRestartReport: Codable {
    let schemaVersion: Int
    let success: Bool
    let requestedAt: Date
    let completedAt: Date
    let beforeProcessIdentifier: Int32?
    let beforeConnectionEpoch: UInt64
    let afterProcessIdentifier: Int32?
    let afterConnectionEpoch: UInt64
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let hostBundleIdentifier = "com.openai.codex"

    private let gate: PetWindowGateConfiguration?
    private let panelController: QuotaPanelController?
    private var locator: PetWindowLocator?
    private var permissionCoordinator: PermissionCoordinator?
    private var lifecycle = AppLifecycleState()
    private var hostProcessIdentifiers: Set<pid_t> = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var hostReconciliationTimer: Timer?
    private var rateClient: CodexRateLimitClient?
    private var rateClientTask: Task<Void, Error>?
    private var rateStateTask: Task<Void, Never>?
    private var pendingReapTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryCoordinator = RecoveryRetryCoordinator()
    private var cliIdentityWatchTask: Task<Void, Never>?
    private var appServerLifecycle = AppServerLifecycleCoordinator()
    private var activeExecutableIdentity: CodexExecutableIdentity?
    private var terminalRecoveryIdentity: CodexExecutableIdentity?
    private var terminalRecoveryIsBlocked = false
    private var crashHealthTimer: Timer?
    private var crashGuard: CrashLoopGuard
    private var permissionIsReady = false
    private var terminationIsPending = false
    private var completedCleanShutdown = false
    #if REBORN_QUOTA_QA
    private var qaOptions: QAControlOptions?
    private var qaControlTask: Task<Void, Never>?
    private var qaControlStarted = false
    private var qaControlCompleted = false
    private var qaControlGeneration: UInt64?
    #endif

    init(crashGuard: CrashLoopGuard) {
        self.crashGuard = crashGuard
        let gate = PetWindowLocator.bundledGate()
        self.gate = gate
        if gate != nil {
            panelController = QuotaPanelController()
        } else {
            panelController = nil
        }
        super.init()
    }

    #if REBORN_QUOTA_QA
    func configureQA(_ options: QAControlOptions?) {
        qaOptions = options
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        hostProcessIdentifiers = runningHostProcessIdentifiers()

        if let gate, let panelController {
            locator = PetWindowLocator(gate: gate) { [weak panelController] update in
                panelController?.apply(update)
            }
            if gate.requiresAX {
                permissionCoordinator = PermissionCoordinator(
                    onReady: { [weak self] in self?.permissionBecameReady() },
                    onDegraded: { [weak self] in self?.permissionBecameUnavailable() }
                )
            } else {
                permissionIsReady = true
            }
        }

        apply(lifecycle.bootstrap(hostIsRunning: !hostProcessIdentifiers.isEmpty))
        if lifecycle.phase == .hostRunning {
            beginPermissionFlowIfNeeded()
        }
        scheduleCrashHealthReset()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginExternalTermination { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        finishCleanShutdown()
    }

    func beginExternalTermination(completion: @escaping @MainActor () -> Void) {
        if completedCleanShutdown {
            completion()
            return
        }
        if !terminationIsPending {
            terminationIsPending = true
            resetRecoveryForHostTransition()
            apply(lifecycle.shutdown())
            permissionCoordinator?.stop()
            #if REBORN_QUOTA_QA
            qaControlTask?.cancel()
            qaControlTask = nil
            qaControlGeneration = nil
            #endif
        }
        let reap = pendingReapTask
        Task { [weak self] in
            if let reap { await reap.value }
            guard let self else { return }
            self.finishCleanShutdown()
            completion()
        }
    }

    func forceCleanExitState() {
        finishCleanShutdown()
    }

    private func apply(_ effects: [AppLifecycleEffect]) {
        for effect in effects {
            switch effect {
            case .installHostMonitors:
                installHostMonitors()
            case .removeHostMonitors:
                removeHostMonitors()
            case .startAppServer:
                startAppServerIfAllowed()
            case .stopAppServerAndReapChild:
                stopAppServerAndReapChild()
            case .startPetLocator:
                startPetLocatorIfAllowed()
            case .stopPetLocator:
                locator?.stop()
            case .hidePanel:
                panelController?.apply(.hidden)
            }
        }
    }

    private func installHostMonitors() {
        guard workspaceObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleIdentifier = application.bundleIdentifier else { return }
            let processIdentifier = application.processIdentifier
            Task { @MainActor in
                self?.hostApplicationLaunched(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
            }
        })
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleIdentifier = application.bundleIdentifier else { return }
            let processIdentifier = application.processIdentifier
            Task { @MainActor in
                self?.hostApplicationTerminated(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
            }
        })
        hostReconciliationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.reconcileHostProcesses() }
        }
    }

    private func removeHostMonitors() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(center.removeObserver)
        workspaceObserverTokens.removeAll()
        hostReconciliationTimer?.invalidate()
        hostReconciliationTimer = nil
    }

    private func hostApplicationLaunched(
        bundleIdentifier: String,
        processIdentifier: pid_t
    ) {
        guard bundleIdentifier == Self.hostBundleIdentifier else { return }
        let wasEmpty = hostProcessIdentifiers.isEmpty
        hostProcessIdentifiers.insert(processIdentifier)
        if wasEmpty {
            apply(lifecycle.hostLaunched())
            beginPermissionFlowIfNeeded()
        }
    }

    private func hostApplicationTerminated(
        bundleIdentifier: String,
        processIdentifier: pid_t
    ) {
        guard bundleIdentifier == Self.hostBundleIdentifier else { return }
        let wasRunning = !hostProcessIdentifiers.isEmpty
        hostProcessIdentifiers.remove(processIdentifier)
        reconcileHostProcesses(previouslyRunning: wasRunning)
    }

    private func reconcileHostProcesses(previouslyRunning: Bool? = nil) {
        let current = runningHostProcessIdentifiers()
        let wasRunning = previouslyRunning ?? !hostProcessIdentifiers.isEmpty
        hostProcessIdentifiers = current
        let isRunning = !current.isEmpty
        if wasRunning, !isRunning {
            resetRecoveryForHostTransition()
            apply(lifecycle.hostTerminated())
        } else if !wasRunning, isRunning {
            apply(lifecycle.hostLaunched())
            beginPermissionFlowIfNeeded()
        }
    }

    private func runningHostProcessIdentifiers() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.bundleIdentifier == Self.hostBundleIdentifier,
                  !application.isTerminated else { return nil }
            return application.processIdentifier
        })
    }

    private func beginPermissionFlowIfNeeded() {
        guard lifecycle.phase == .hostRunning else { return }
        if gate?.requiresAX == true {
            permissionCoordinator?.start()
        } else if gate != nil {
            permissionBecameReady()
        }
    }

    private func permissionBecameReady() {
        permissionIsReady = true
        guard lifecycle.phase == .hostRunning else { return }
        if terminalRecoveryIsBlocked {
            startCLIIdentityWatch()
        }
        startPetLocatorIfAllowed()
        startAppServerIfAllowed()
    }

    private func permissionBecameUnavailable() {
        permissionIsReady = false
        cliIdentityWatchTask?.cancel()
        cliIdentityWatchTask = nil
        locator?.stop()
        stopAppServerAndReapChild()
        panelController?.apply(.hidden)
    }

    private func startPetLocatorIfAllowed() {
        guard permissionIsReady, lifecycle.phase == .hostRunning else { return }
        locator?.start()
    }

    private func startAppServerIfAllowed() {
        applyAppServerEffects(appServerLifecycle.requestStart(
            hostPresent: lifecycle.phase == .hostRunning,
            permissionReady: permissionIsReady,
            blocked: terminalRecoveryIsBlocked
        ))
    }

    private func applyAppServerEffects(_ effects: [AppServerLifecycleEffect]) {
        for effect in effects {
            switch effect {
            case .start(let generation):
                startAppServer(generation: generation)
            case .cancelAndReap(let generation):
                cancelAndReapAppServer(generation: generation)
            }
        }
    }

    private func startAppServer(generation: UInt64) {
        guard appServerLifecycle.activeGeneration == generation,
              permissionIsReady,
              lifecycle.phase == .hostRunning,
              !terminalRecoveryIsBlocked,
              let panelController else { return }

        let client = CodexRateLimitClient()
        rateClient = client
        panelController.updateQuota(.loading)
        rateStateTask = Task { [weak panelController] in
            for await state in client.states {
                guard !Task.isCancelled else { return }
                panelController?.updateQuota(state)
            }
        }
        rateClientTask = Task { [weak self] in
            var locatedIdentity: CodexExecutableIdentity?
            do {
                let executable = try await CodexExecutableLocator().locate()
                locatedIdentity = executable.identity
                try Task.checkCancellation()
                self?.recordExecutableIdentity(
                    executable.identity,
                    generation: generation
                )
                try await client.runUntilCancelled(executable: executable)
                self?.appServerRunEnded(
                    generation: generation,
                    identity: locatedIdentity,
                    action: .retryAfterBackoff
                )
            } catch is CancellationError {
                self?.appServerRunEnded(
                    generation: generation,
                    identity: locatedIdentity,
                    action: .stop
                )
            } catch let error as CodexRateLimitClientError {
                self?.appServerRunEnded(
                    generation: generation,
                    identity: locatedIdentity,
                    action: CodexClientRecoveryPolicy.action(for: error)
                )
            } catch {
                self?.appServerRunEnded(
                    generation: generation,
                    identity: locatedIdentity,
                    action: .waitForHostOrExecutableIdentityChange
                )
            }
        }
        #if REBORN_QUOTA_QA
        startQAControlIfNeeded(client: client, generation: generation)
        #endif
    }

    private func stopAppServerAndReapChild() {
        applyRecoveryRetryEffects(retryCoordinator.cancel())
        applyAppServerEffects(appServerLifecycle.requestStop())
    }

    private func cancelAndReapAppServer(generation: UInt64) {
        rateStateTask?.cancel()
        rateStateTask = nil
        let clientTask = rateClientTask
        rateClientTask?.cancel()
        rateClientTask = nil
        rateClient = nil
        activeExecutableIdentity = nil
        #if REBORN_QUOTA_QA
        if qaControlGeneration == generation {
            qaControlTask?.cancel()
            qaControlTask = nil
            qaControlGeneration = nil
            if !qaControlCompleted { qaControlStarted = false }
        }
        #endif
        let previousReap = pendingReapTask
        pendingReapTask = Task { [weak self] in
            if let previousReap { await previousReap.value }
            if let clientTask { _ = await clientTask.result }
            self?.appServerReapCompleted(generation: generation)
        }
    }

    private func appServerReapCompleted(generation: UInt64) {
        pendingReapTask = nil
        applyAppServerEffects(appServerLifecycle.reapCompleted(
            generation: generation,
            hostPresent: lifecycle.phase == .hostRunning,
            permissionReady: permissionIsReady,
            blocked: terminalRecoveryIsBlocked
        ))
    }

    private func recordExecutableIdentity(
        _ identity: CodexExecutableIdentity,
        generation: UInt64
    ) {
        guard appServerLifecycle.activeGeneration == generation else { return }
        activeExecutableIdentity = identity
    }

    private func appServerRunEnded(
        generation: UInt64,
        identity: CodexExecutableIdentity?,
        action: CodexClientRecoveryAction
    ) {
        guard appServerLifecycle.runEnded(generation: generation) else { return }
        rateStateTask?.cancel()
        rateStateTask = nil
        rateClientTask = nil
        rateClient = nil
        activeExecutableIdentity = nil
        #if REBORN_QUOTA_QA
        if qaControlGeneration == generation {
            qaControlTask?.cancel()
            qaControlTask = nil
            qaControlGeneration = nil
            if !qaControlCompleted { qaControlStarted = false }
        }
        #endif

        switch action {
        case .stop:
            return
        case .retryAfterBackoff:
            panelController?.updateQuota(.unavailable(.transportError))
            scheduleRecoveryRetry(after: 30)
        case .retryAuthenticationAfter(let seconds):
            panelController?.updateQuota(.unavailable(.transportError))
            scheduleRecoveryRetry(after: seconds)
        case .waitForHostOrExecutableIdentityChange:
            panelController?.updateQuota(.unavailable(.transportError))
            terminalRecoveryIdentity = identity
            terminalRecoveryIsBlocked = true
            startCLIIdentityWatch()
        }
    }

    private func scheduleRecoveryRetry(after seconds: TimeInterval) {
        applyRecoveryRetryEffects(retryCoordinator.schedule(after: seconds))
    }

    private func applyRecoveryRetryEffects(_ effects: [RecoveryRetryEffect]) {
        for effect in effects {
            switch effect {
            case .schedule(let token, let delay):
                retryTask = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(
                            for: .milliseconds(Int64(delay * 1_000))
                        )
                        try Task.checkCancellation()
                        self?.recoveryRetryTimerFired(token: token)
                    } catch {}
                }
            case .cancel:
                retryTask?.cancel()
                retryTask = nil
            }
        }
    }

    private func recoveryRetryTimerFired(token: UInt64) {
        let runtimeEligible = lifecycle.phase == .hostRunning
            && permissionIsReady
            && !terminalRecoveryIsBlocked
            && !terminationIsPending
        retryTask = nil
        if retryCoordinator.timerFired(
            token: token,
            runtimeEligible: runtimeEligible
        ) {
            startAppServerIfAllowed()
        }
    }

    private func startCLIIdentityWatch() {
        cliIdentityWatchTask?.cancel()
        let baseline = terminalRecoveryIdentity
        cliIdentityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(for: .seconds(30))
                    try Task.checkCancellation()
                    guard let self else { return }
                    guard self.lifecycle.phase == .hostRunning,
                          self.permissionIsReady,
                          self.terminalRecoveryIsBlocked else {
                        self.cliIdentityWatchTask = nil
                        return
                    }
                    let located = try await CodexExecutableLocator().locate()
                    if baseline == nil || located.identity != baseline {
                        self.terminalRecoveryIsBlocked = false
                        self.terminalRecoveryIdentity = nil
                        self.cliIdentityWatchTask = nil
                        self.startAppServerIfAllowed()
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func resetRecoveryForHostTransition() {
        terminalRecoveryIsBlocked = false
        terminalRecoveryIdentity = nil
        cliIdentityWatchTask?.cancel()
        cliIdentityWatchTask = nil
        applyRecoveryRetryEffects(retryCoordinator.cancel())
    }

    private func scheduleCrashHealthReset() {
        crashHealthTimer?.invalidate()
        crashHealthTimer = Timer.scheduledTimer(
            withTimeInterval: CrashLoopGuard.healthyResetInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard var guardrail = self?.crashGuard else { return }
                _ = try? guardrail.markHealthyIfEligible()
                self?.crashGuard = guardrail
            }
        }
    }

    private func finishCleanShutdown() {
        guard !completedCleanShutdown else { return }
        completedCleanShutdown = true
        crashHealthTimer?.invalidate()
        crashHealthTimer = nil
        permissionCoordinator?.stop()
        removeHostMonitors()
        panelController?.shutdown()
        try? crashGuard.markCleanExit()
    }

    #if REBORN_QUOTA_QA
    private func startQAControlIfNeeded(
        client: CodexRateLimitClient,
        generation: UInt64
    ) {
        guard !qaControlStarted, !qaControlCompleted, let qaOptions else { return }
        qaControlStarted = true
        qaControlGeneration = generation
        qaControlTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: qaOptions.restartChildAfter)
                try Task.checkCancellation()
                guard let self,
                      self.appServerLifecycle.activeGeneration == generation,
                      self.rateClient === client,
                      self.qaControlGeneration == generation else { return }
                let requestedAt = Date()
                let before = await client.qaRestartOwnedChild()
                let deadline = ContinuousClock().now.advanced(by: .seconds(30))
                var after = await client.qaChildSnapshot()
                while ContinuousClock().now < deadline,
                      (after.connectionEpoch <= before.connectionEpoch ||
                       after.processIdentifier == before.processIdentifier ||
                       after.processIdentifier == nil) {
                    try await ContinuousClock().sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    guard self.appServerLifecycle.activeGeneration == generation,
                          self.rateClient === client,
                          self.qaControlGeneration == generation else { return }
                    after = await client.qaChildSnapshot()
                }
                let success = before.processIdentifier != nil
                    && after.processIdentifier != nil
                    && after.processIdentifier != before.processIdentifier
                    && after.connectionEpoch > before.connectionEpoch
                let report = QAChildRestartReport(
                    schemaVersion: 1,
                    success: success,
                    requestedAt: requestedAt,
                    completedAt: Date(),
                    beforeProcessIdentifier: before.processIdentifier,
                    beforeConnectionEpoch: before.connectionEpoch,
                    afterProcessIdentifier: after.processIdentifier,
                    afterConnectionEpoch: after.connectionEpoch
                )
                guard self.appServerLifecycle.activeGeneration == generation,
                      self.rateClient === client,
                      self.qaControlGeneration == generation else { return }
                let data = try JSONEncoder().encode(report)
                try data.write(to: qaOptions.reportURL, options: [.atomic])
                self.qaControlCompleted = true
                self.qaControlStarted = false
                self.qaControlGeneration = nil
                self.qaControlTask = nil
            } catch {
                // QA output is intentionally best-effort and contains no quota
                // payload or authentication material.
                self?.qaControlDidEndWithoutReport(generation: generation)
            }
        }
    }

    private func qaControlDidEndWithoutReport(generation: UInt64) {
        guard qaControlGeneration == generation else { return }
        qaControlTask = nil
        qaControlGeneration = nil
        if !qaControlCompleted { qaControlStarted = false }
    }
    #endif
}
