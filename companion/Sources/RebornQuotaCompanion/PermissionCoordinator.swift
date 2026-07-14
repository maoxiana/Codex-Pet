import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import RebornQuotaCore

@MainActor
final class PermissionCoordinator {
    typealias Callback = @MainActor () -> Void

    private static let persistenceKey = "accessibilityPermissionState.v1"

    private let defaults: UserDefaults
    private let onReady: Callback
    private let onDegraded: Callback
    private var machine: PermissionStateMachine
    private var recheckTimer: Timer?
    private var hasStarted = false

    init(
        defaults: UserDefaults = .standard,
        onReady: @escaping Callback,
        onDegraded: @escaping Callback
    ) {
        self.defaults = defaults
        self.onReady = onReady
        self.onDegraded = onDegraded
        let persistence = Self.loadPersistence(from: defaults)
        machine = PermissionStateMachine(
            requiresAX: true,
            persistence: persistence,
            trusted: AXIsProcessTrusted(),
            now: Date(),
            currentIdentity: Self.currentExecutableIdentity()
        )
    }

    func start() {
        guard !hasStarted else {
            recheckNow()
            return
        }
        hasStarted = true
        apply(machine.bootstrap())
    }

    func stop() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    private func apply(_ effects: [PermissionEffect]) {
        for effect in effects {
            switch effect {
            case .showRationale:
                showRationale()
            case .requestSystemPrompt:
                requestSystemPrompt()
            case .persist(let persistence):
                persist(persistence)
            case .hideForDegradedMode:
                onDegraded()
            case .scheduleTrustRecheck(let interval):
                scheduleRecheck(after: interval)
            case .permissionReady:
                recheckTimer?.invalidate()
                recheckTimer = nil
                onReady()
            case .openAccessibilitySettings:
                NSWorkspace.shared.open(PermissionStateMachine.accessibilitySettingsURL)
            case .showRecoveryAffordance:
                showRecoveryAffordance()
            }
        }
    }

    private func showRationale() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "允许 RebornQuota 定位 Reborn"
        alert.informativeText = "为了让额度气泡跟随 Codex 桌面宠物，RebornQuota 需要读取宠物窗口的位置。它不会读取键盘输入。每次重新构建的临时签名都可能让 macOS 要求重新授权。"
        alert.addButton(withTitle: "继续授权")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "打开系统设置")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            apply(machine.rationaleAccepted())
        case .alertThirdButtonReturn:
            apply(machine.rationaleDeclined(now: Date()))
            apply(machine.openSettings())
        default:
            apply(machine.rationaleDeclined(now: Date()))
        }
    }

    private func requestSystemPrompt() {
        let trusted = AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary)
        apply(machine.systemPromptCompleted(trusted: trusted, now: Date()))
    }

    private func showRecoveryAffordance() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RebornQuota 暂时无法定位 Reborn"
        alert.informativeText = "辅助功能权限可能曾被拒绝，或因应用重新构建而失效。你可以在系统设置中重新开启；RebornQuota 不会再次弹出系统授权请求。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            apply(machine.openSettings())
        }
    }

    private func scheduleRecheck(after interval: TimeInterval) {
        recheckTimer?.invalidate()
        recheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.recheckNow() }
        }
    }

    private func recheckNow() {
        apply(machine.recheck(trusted: AXIsProcessTrusted(), now: Date()))
    }

    private func persist(_ persistence: PermissionPersistence) {
        guard let data = try? JSONEncoder().encode(persistence) else { return }
        defaults.set(data, forKey: Self.persistenceKey)
    }

    private static func loadPersistence(from defaults: UserDefaults) -> PermissionPersistence {
        guard let data = defaults.data(forKey: persistenceKey),
              let value = try? JSONDecoder().decode(PermissionPersistence.self, from: data) else {
            return .empty
        }
        return value
    }

    private static func currentExecutableIdentity() -> String {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return "unavailable"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
