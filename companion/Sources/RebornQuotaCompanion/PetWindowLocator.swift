import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import RebornQuotaCore

struct LocatedPetWindow: Equatable {
    let petFrame: RectValue
    let screenVisibleFrame: RectValue
    let screenID: UInt32
    let petLayer: Int
}

enum PetWindowLocationUpdate: Equatable {
    case visible(LocatedPetWindow)
    case hidden
}

@MainActor
protocol RuntimeAXEvidenceProviding: AnyObject {
    var notificationsAreActive: Bool { get }
    var isTrustedForAccessibility: Bool { get }
    func start(invalidationHandler: @escaping @MainActor () -> Void)
    func snapshot() -> AXSnapshotDocument?
    func stop()
}

@MainActor
protocol RuntimeWindowSnapshotProviding: AnyObject {
    func snapshot() -> WindowSnapshotDocument?
}

@MainActor
protocol LocatorScheduling: AnyObject {
    func scheduleImmediate(_ operation: @escaping @MainActor () -> Void)
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    )
    func cancelAll()
}

@MainActor
final class PetWindowLocator: NSObject {
    typealias UpdateHandler = @MainActor (PetWindowLocationUpdate) -> Void

    private let gate: PetWindowGateConfiguration
    private let resolver: RuntimePetWindowResolver
    private let axProvider: any RuntimeAXEvidenceProviding
    private let windowProvider: any RuntimeWindowSnapshotProviding
    private let scheduler: any LocatorScheduling
    private let updateHandler: UpdateHandler
    private var pollCoordinator = LocatorPollCoordinator()
    private var cadence = LocatorPollingCadence()
    private var lastBounds: RectValue?

    init(
        gate: PetWindowGateConfiguration,
        axProvider: (any RuntimeAXEvidenceProviding)? = nil,
        windowProvider: (any RuntimeWindowSnapshotProviding)? = nil,
        scheduler: (any LocatorScheduling)? = nil,
        updateHandler: @escaping UpdateHandler
    ) {
        self.gate = gate
        resolver = RuntimePetWindowResolver(gate: gate)
        self.axProvider = axProvider ?? LiveAXEvidenceProvider(
            requirement: gate.discriminator.axRequirement
        )
        self.windowProvider = windowProvider ?? SystemWindowSnapshotProvider()
        self.scheduler = scheduler ?? RunLoopLocatorScheduler()
        self.updateHandler = updateHandler
    }

    static func bundledGate() -> PetWindowGateConfiguration? {
        let packagedCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("gate-result.json"),
            Bundle.main.resourceURL?
                .appendingPathComponent("RebornQuotaCompanion_RebornQuotaCompanion.bundle")
                .appendingPathComponent("gate-result.json"),
        ]
        for case let url? in packagedCandidates {
            guard let data = try? Data(contentsOf: url),
                  let gate = PetWindowGateConfiguration.decodeValidated(from: data) else {
                continue
            }
            return gate
        }
        // Bundle.module's generated accessor traps if its bundle is absent.
        // A packaged app must fail closed rather than falling through to that
        // development-only lookup after a damaged install.
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "app",
              let url = Bundle.module.url(forResource: "gate-result", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PetWindowGateConfiguration.decodeValidated(from: data)
    }

    func start() {
        guard !pollCoordinator.isRunning else { return }
        pollCoordinator.start()
        axProvider.start { [weak self] in
            self?.receiveInvalidation()
        }
        receiveInvalidation()
    }

    func stop() {
        pollCoordinator.stop()
        scheduler.cancelAll()
        lastBounds = nil
        cadence.reset()
        axProvider.stop()
        updateHandler(.hidden)
    }

    private func receiveInvalidation() {
        guard pollCoordinator.receiveInvalidation() else { return }
        scheduleImmediatePoll()
    }

    private func scheduleImmediatePoll() {
        scheduler.scheduleImmediate { [weak self] in
            guard let self,
                  self.pollCoordinator.beginImmediatePoll() else { return }
            self.performPoll()
            if self.pollCoordinator.finishPoll() {
                self.scheduleImmediatePoll()
            }
        }
    }

    private func timerFired() {
        guard pollCoordinator.beginTimerPoll() else { return }
        performPoll()
        if pollCoordinator.finishPoll() {
            scheduleImmediatePoll()
        }
    }

    private func performPoll() {
        guard let document = windowProvider.snapshot() else {
            publishHiddenAndRetry()
            return
        }
        let axDocument = gate.requiresAX ? axProvider.snapshot() : nil
        guard case .visible(let resolved) = resolver.resolve(
            document: document,
            axDocument: axDocument,
            accessibilityTrustedFallback: axProvider.isTrustedForAccessibility
        ) else {
            publishHiddenAndRetry()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let boundsChanged = lastBounds != resolved.petFrame
        lastBounds = resolved.petFrame
        updateHandler(.visible(LocatedPetWindow(
            petFrame: resolved.petFrame,
            screenVisibleFrame: resolved.screenVisibleFrame,
            screenID: resolved.screenID,
            petLayer: resolved.petLayer
        )))

        schedule(after: cadence.interval(
            notificationsActive: axProvider.notificationsAreActive,
            boundsChanged: boundsChanged,
            now: now
        ))
    }

    private func publishHiddenAndRetry() {
        lastBounds = nil
        cadence.reset()
        updateHandler(.hidden)
        schedule(after: axProvider.notificationsAreActive ? 1.0 : 0.100)
    }

    private func schedule(after interval: TimeInterval) {
        guard pollCoordinator.isRunning else { return }
        scheduler.scheduleRepeating(every: interval) { [weak self] in
            self?.timerFired()
        }
    }
}

@MainActor
private final class SystemWindowSnapshotProvider: RuntimeWindowSnapshotProviding {
    func snapshot() -> WindowSnapshotDocument? {
        let screens = currentScreens()
        guard !screens.isEmpty,
              let metadata = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        let bundleByPID = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0.bundleIdentifier)
            }
        )
        let windows = metadata.enumerated().compactMap { order, dictionary -> WindowSnapshot? in
            guard let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  bundleByPID[pid] == "com.openai.codex",
                  let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDictionary),
                  cgRect.width > 0,
                  cgRect.height > 0 else {
                return nil
            }
            return WindowSnapshot(
                windowNumber: WindowNumberMetadataParser.parse(
                    dictionary[kCGWindowNumber as String] as? NSNumber
                ),
                ownerPID: pid,
                resolvedBundleID: "com.openai.codex",
                ownerName: dictionary[kCGWindowOwnerName as String] as? String,
                layer: layer,
                bounds: RectValue(
                    x: cgRect.minX,
                    y: cgRect.minY,
                    width: cgRect.width,
                    height: cgRect.height
                ),
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                isOnScreen: true,
                sharingState: nil,
                title: nil,
                order: order
            )
        }
        return WindowSnapshotDocument(
            schemaVersion: 1,
            state: "runtime",
            screens: screens,
            windows: windows
        )
    }

    private func currentScreens() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let cgFrame = CGDisplayBounds(id)
            return DisplayGeometry(
                id: id,
                cgFrame: RectValue(
                    x: cgFrame.minX,
                    y: cgFrame.minY,
                    width: cgFrame.width,
                    height: cgFrame.height
                ),
                appKitFrame: RectValue(
                    x: screen.frame.minX,
                    y: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                appKitVisibleFrame: RectValue(
                    x: screen.visibleFrame.minX,
                    y: screen.visibleFrame.minY,
                    width: screen.visibleFrame.width,
                    height: screen.visibleFrame.height
                ),
                backingScaleFactor: screen.backingScaleFactor
            )
        }.sorted { $0.id < $1.id }
    }
}

@MainActor
private final class RunLoopLocatorScheduler: NSObject, LocatorScheduling {
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var generation: UInt64 = 0

    func scheduleImmediate(_ operation: @escaping @MainActor () -> Void) {
        let capturedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == capturedGeneration else { return }
            operation()
        }
    }

    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) {
        guard timer?.isValid != true || timerInterval != interval else { return }
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in operation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancelAll() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        timerInterval = nil
    }
}

private final class AXInvalidationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var deliveryPending = false

    func setCallback(_ callback: (@Sendable () -> Void)?) {
        lock.lock()
        self.callback = callback
        if callback == nil { deliveryPending = false }
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !deliveryPending, let callback else {
            lock.unlock()
            return
        }
        deliveryPending = true
        lock.unlock()
        callback()
    }

    func acknowledgeDelivery() {
        lock.lock()
        deliveryPending = false
        lock.unlock()
    }
}

private func liveAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<AXInvalidationSignal>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .fire()
}

@MainActor
private final class LiveAXEvidenceProvider: RuntimeAXEvidenceProviding {
    private struct CapturedWindow {
        let element: AXUIElement
        let node: AXNodeSnapshot
    }

    private let requirement: AXRequirement?
    private let signal = AXInvalidationSignal()
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var source: CFRunLoopSource?
    private(set) var notificationsAreActive = false

    var isTrustedForAccessibility: Bool { AXIsProcessTrusted() }

    init(requirement: AXRequirement?) {
        self.requirement = requirement
    }

    func start(invalidationHandler: @escaping @MainActor () -> Void) {
        signal.setCallback { [weak signal] in
            Task { @MainActor in
                signal?.acknowledgeDelivery()
                invalidationHandler()
            }
        }
    }

    func snapshot() -> AXSnapshotDocument? {
        guard AXIsProcessTrusted(),
              let requirement,
              requirement.predicate == .rebornObserved else {
            stopObservation()
            return nil
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.openai.codex"
        }
        guard applications.count == 1, let application = applications.first else {
            stopObservation()
            return nil
        }

        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let windows = readBoundedElements(
            app,
            kAXWindowsAttribute as CFString,
            limit: 128
        ) else {
            stopObservation()
            return nil
        }
        let captured = windows.map { window -> CapturedWindow in
            let role = readString(window, kAXRoleAttribute as CFString, optional: false)
            let subrole = readString(window, kAXSubroleAttribute as CFString, optional: true)
            let node: AXNodeSnapshot
            if role.value == requirement.predicate.role,
               subrole.value == requirement.predicate.subrole {
                node = captureNode(
                    window,
                    knownRole: role,
                    knownSubrole: subrole
                )
            } else {
                // Irrelevant direct windows are represented truthfully without a deep
                // descendant allocation; the validator rejects them by role/subrole.
                node = incompleteNode(
                    window,
                    role: role,
                    subrole: subrole,
                    childCount: reportedChildCount(window)
                )
            }
            return CapturedWindow(element: window, node: node)
        }
        let structural = captured.filter { requirement.predicate.matches($0.node) }
        guard structural.count == 1, let candidate = structural.first else {
            stopObservation()
            return nil
        }
        guard let notificationEvidence = configureObservation(
            pid: pid,
            candidate: candidate.element,
            allWindows: captured,
            predicate: requirement.predicate
        ) else {
            return nil
        }
        guard let capturedBounds = candidate.node.bounds,
              AXRegistrationStabilityPolicy.isStable(
                captured: capturedBounds,
                current: readBounds(candidate.element),
                tolerance: 2
              ) else {
            stopObservation()
            return nil
        }
        let appRole = readString(app, kAXRoleAttribute as CFString, optional: false)
        let appSubrole = readString(app, kAXSubroleAttribute as CFString, optional: true)
        let root = AXNodeSnapshot(
            role: appRole.value,
            subrole: appSubrole.value,
            identifier: nil,
            bounds: nil,
            childCount: captured.count,
            children: captured.map(\.node),
            roleReadSucceeded: appRole.succeeded,
            subroleReadSucceeded: appSubrole.succeeded,
            childrenReadSucceeded: true,
            childrenComplete: captured.allSatisfy { $0.node.subtreeIsComplete }
        )
        return AXSnapshotDocument(
            schemaVersion: 2,
            trustedForAccessibility: true,
            coordinateSpace: .cgGlobalTopLeft,
            processes: [AXProcessSnapshot(
                pid: pid,
                bundleID: "com.openai.codex",
                observerCreationErrorCode: 0,
                notifications: notificationEvidence,
                tree: root,
                windowsReadSucceeded: true
            )]
        )
    }

    func stop() {
        signal.setCallback(nil)
        stopObservation()
    }

    private func configureObservation(
        pid: pid_t,
        candidate: AXUIElement,
        allWindows: [CapturedWindow],
        predicate: AXWindowStructuralPredicate
    ) -> [AXNotificationProbe]? {
        stopObservation()
        var created: AXObserver?
        guard AXObserverCreate(pid, liveAXObserverCallback, &created) == .success,
              let created else { return nil }

        let refcon = Unmanaged.passUnretained(signal).toOpaque()
        var candidateRegistrations: [String] = []
        var evidence: [AXNotificationProbe] = []
        for window in allWindows where
            window.node.role == predicate.role
                && window.node.subrole == predicate.subrole {
            for notification in predicate.requiredWindowNotifications {
                let isCandidate = CFEqual(window.element, candidate)
                let error = AXObserverAddNotification(
                    created,
                    window.element,
                    notification as CFString,
                    isCandidate ? refcon : nil
                )
                evidence.append(AXNotificationProbe(
                    targetRole: window.node.role,
                    notification: notification,
                    errorCode: error.rawValue
                ))
                guard error == .success else {
                    for registered in candidateRegistrations {
                        AXObserverRemoveNotification(
                            created,
                            candidate,
                            registered as CFString
                        )
                    }
                    return nil
                }
                if isCandidate {
                    candidateRegistrations.append(notification)
                } else {
                    AXObserverRemoveNotification(
                        created,
                        window.element,
                        notification as CFString
                    )
                }
            }
        }
        let runLoopSource = AXObserverGetRunLoopSource(created)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        observer = created
        observedElement = candidate
        source = runLoopSource
        notificationsAreActive = true
        return evidence
    }

    private func stopObservation() {
        if let observer, let observedElement, let requirement {
            for notification in requirement.predicate.requiredWindowNotifications {
                AXObserverRemoveNotification(
                    observer,
                    observedElement,
                    notification as CFString
                )
            }
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observer = nil
        observedElement = nil
        source = nil
        notificationsAreActive = false
    }

    private func captureNode(
        _ root: AXUIElement,
        knownRole: (value: String?, succeeded: Bool)? = nil,
        knownSubrole: (value: String?, succeeded: Bool)? = nil,
        descendantLimit: Int = 512
    ) -> AXNodeSnapshot {
        let role = knownRole
            ?? readString(root, kAXRoleAttribute as CFString, optional: false)
        let subrole = knownSubrole
            ?? readString(root, kAXSubroleAttribute as CFString, optional: true)
        var budget = AXTraversalBudget(limit: descendantLimit)
        let childRead = readBoundedChildren(root, budget: &budget)
        guard childRead.succeeded, let children = childRead.children else {
            return AXNodeSnapshot(
                role: role.value,
                subrole: subrole.value,
                identifier: nil,
                bounds: readBounds(root),
                childCount: childRead.reportedCount,
                children: [],
                roleReadSucceeded: role.succeeded,
                subroleReadSucceeded: subrole.succeeded,
                childrenReadSucceeded: false,
                childrenComplete: false
            )
        }
        let captured = children.map { captureDescendant($0, budget: &budget) }
        let complete = captured.allSatisfy(\.subtreeIsComplete)
        return AXNodeSnapshot(
            role: role.value,
            subrole: subrole.value,
            identifier: nil,
            bounds: readBounds(root),
            childCount: children.count,
            children: captured,
            roleReadSucceeded: role.succeeded,
            subroleReadSucceeded: subrole.succeeded,
            childrenReadSucceeded: true,
            childrenComplete: complete
        )
    }

    private func captureDescendant(
        _ element: AXUIElement,
        budget: inout AXTraversalBudget
    ) -> AXNodeSnapshot {
        let role = readString(element, kAXRoleAttribute as CFString, optional: false)
        let subrole = readString(element, kAXSubroleAttribute as CFString, optional: true)
        let childRead = readBoundedChildren(element, budget: &budget)
        guard childRead.succeeded, let children = childRead.children else {
            return incompleteNode(
                element,
                role: role,
                subrole: subrole,
                childCount: childRead.reportedCount
            )
        }
        let captured = children.map { captureDescendant($0, budget: &budget) }
        return AXNodeSnapshot(
            role: role.value,
            subrole: subrole.value,
            identifier: nil,
            bounds: readBounds(element),
            childCount: children.count,
            children: captured,
            roleReadSucceeded: role.succeeded,
            subroleReadSucceeded: subrole.succeeded,
            childrenReadSucceeded: true,
            childrenComplete: captured.allSatisfy(\.subtreeIsComplete)
        )
    }

    private func incompleteNode(
        _ element: AXUIElement,
        role: (value: String?, succeeded: Bool),
        subrole: (value: String?, succeeded: Bool),
        childCount: Int
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: role.value,
            subrole: subrole.value,
            identifier: nil,
            bounds: readBounds(element),
            childCount: childCount,
            children: [],
            roleReadSucceeded: role.succeeded,
            subroleReadSucceeded: subrole.succeeded,
            childrenReadSucceeded: false,
            childrenComplete: false
        )
    }

    private func readString(
        _ element: AXUIElement,
        _ attribute: CFString,
        optional: Bool
    ) -> (value: String?, succeeded: Bool) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        if optional, error == .noValue { return (nil, true) }
        guard error == .success, value == nil || value is String else {
            return (nil, false)
        }
        return (value as? String, true)
    }

    private func readBoundedElements(
        _ element: AXUIElement,
        _ attribute: CFString,
        limit: Int
    ) -> [AXUIElement]? {
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, attribute, &count)
        if countError == .noValue { return [] }
        guard countError == .success,
              count >= 0,
              count <= limit else { return nil }
        guard count > 0 else { return [] }
        var values: CFArray?
        let copyError = AXUIElementCopyAttributeValues(
            element,
            attribute,
            0,
            count,
            &values
        )
        guard copyError == .success,
              let result = values as? [AXUIElement],
              result.count == count else { return nil }
        return result
    }

    private func reportedChildCount(_ element: AXUIElement) -> Int {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &count
        )
        guard error == .success, count >= 0 else { return 0 }
        return Int(count)
    }

    private func readBoundedChildren(
        _ element: AXUIElement,
        budget: inout AXTraversalBudget
    ) -> (reportedCount: Int, children: [AXUIElement]?, succeeded: Bool) {
        let attribute = kAXChildrenAttribute as CFString
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, attribute, &count)
        let status: AXAttributeReadStatus
        switch countError {
        case .success:
            status = .success
        case .noValue:
            status = .noValue
        default:
            status = .failure(countError.rawValue)
        }
        guard let boundedCount = try? AXBoundedChildCountPolicy.reserve(
            status: status,
            reportedCount: Int(count),
            budget: &budget
        ) else {
            return (max(0, Int(count)), nil, false)
        }
        guard boundedCount > 0 else { return (0, [], true) }

        var values: CFArray?
        let copyError = AXUIElementCopyAttributeValues(
            element,
            attribute,
            0,
            CFIndex(boundedCount),
            &values
        )
        guard copyError == .success,
              let result = values as? [AXUIElement],
              result.count == boundedCount else {
            return (boundedCount, nil, false)
        }
        return (boundedCount, result, true)
    }

    private func readBounds(_ element: AXUIElement) -> RectValue? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return RectValue(
            x: point.x,
            y: point.y,
            width: size.width,
            height: size.height
        )
    }
}
