import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import RebornQuotaCore

private let codexBundleID = "com.openai.codex"

private enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case captureFailed(String)
    case decodingFailed(String)
    case ambiguousDiscriminator(String)
    case gateFailed

    var description: String {
        switch self {
        case .usage(let message), .invalidArgument(let message), .captureFailed(let message),
             .decodingFailed(let message), .ambiguousDiscriminator(let message):
            return message
        case .gateFailed:
            return "Evaluation gate failed; gate result was written"
        }
    }
}

private typealias SnapshotDocument = WindowSnapshotDocument

private struct BehaviorEvidenceObservation: Codable, Sendable {
    let snapshot: String
    let available: Bool
    let candidateCount: Int?
}

private struct GateResult: Codable, Sendable {
    let schemaVersion: Int
    let passed: Bool
    let identificationPassed: Bool
    let performanceVerified: Bool
    let performanceDeferred: Bool
    let deferralNote: String?
    let requiresAX: Bool
    let petLayer: Int?
    let discriminator: PetDiscriminator?
    let maxMovementDetectionMs: Double?
    let maxFollowLatencyMs: Double?
    let idleCPUPercent: Double?
    let movingCPUPercent: Double?
    let missingSnapshots: [String]
    let missingMetrics: [String]
    let failures: [String]
    let warnings: [String]
    let behaviorEvidence: [BehaviorEvidenceObservation]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case passed
        case identificationPassed
        case performanceVerified
        case performanceDeferred
        case deferralNote
        case requiresAX
        case petLayer
        case discriminator
        case maxMovementDetectionMs
        case maxFollowLatencyMs
        case idleCPUPercent
        case movingCPUPercent
        case missingSnapshots
        case missingMetrics
        case failures
        case warnings
        case behaviorEvidence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(passed, forKey: .passed)
        try container.encode(identificationPassed, forKey: .identificationPassed)
        try container.encode(performanceVerified, forKey: .performanceVerified)
        try container.encode(performanceDeferred, forKey: .performanceDeferred)
        try container.encode(deferralNote, forKey: .deferralNote)
        try container.encode(requiresAX, forKey: .requiresAX)
        try container.encode(petLayer, forKey: .petLayer)
        try container.encode(discriminator, forKey: .discriminator)
        try container.encode(maxMovementDetectionMs, forKey: .maxMovementDetectionMs)
        try container.encode(maxFollowLatencyMs, forKey: .maxFollowLatencyMs)
        try container.encode(idleCPUPercent, forKey: .idleCPUPercent)
        try container.encode(movingCPUPercent, forKey: .movingCPUPercent)
        try container.encode(missingSnapshots, forKey: .missingSnapshots)
        try container.encode(missingMetrics, forKey: .missingMetrics)
        try container.encode(failures, forKey: .failures)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(behaviorEvidence, forKey: .behaviorEvidence)
    }
}

private enum ProbeJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func write<T: Encodable>(_ value: T, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw ProbeError.decodingFailed("Could not decode \(path): \(error)")
        }
    }
}

private struct ParsedArguments {
    let options: [String: String]
    let flags: Set<String>

    init(_ arguments: ArraySlice<String>, repeatableOptions: Set<String> = []) throws {
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw ProbeError.invalidArgument("Unexpected argument: \(key)")
            }
            let next = arguments.index(after: index)
            if next < arguments.endIndex, !arguments[next].hasPrefix("--") {
                guard options[key] == nil || repeatableOptions.contains(key) else {
                    throw ProbeError.invalidArgument("Duplicate option: \(key)")
                }
                options[key] = arguments[next]
                index = arguments.index(after: next)
            } else {
                flags.insert(key)
                index = next
            }
        }
        self.options = options
        self.flags = flags
    }

    func required(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw ProbeError.invalidArgument("Missing required option \(key)")
        }
        return value
    }

    func double(_ key: String) throws -> Double {
        let value = try required(key)
        guard let result = Double(value), result > 0, result.isFinite else {
            throw ProbeError.invalidArgument("\(key) must be a positive finite number")
        }
        return result
    }

    func repeatedValues(for key: String, in raw: ArraySlice<String>) throws -> [String] {
        var values: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == key {
                let next = raw.index(after: index)
                guard next < raw.endIndex, !raw[next].hasPrefix("--") else {
                    throw ProbeError.invalidArgument("Missing value for \(key)")
                }
                values.append(raw[next])
                index = raw.index(after: next)
            } else {
                index = raw.index(after: index)
            }
        }
        return values
    }

    func validate(allowedOptions: Set<String>, allowedFlags: Set<String> = []) throws {
        let unknownOptions = Set(options.keys).subtracting(allowedOptions)
        let unknownFlags = flags.subtracting(allowedFlags)
        if let unknown = (unknownOptions.union(unknownFlags)).sorted().first {
            throw ProbeError.invalidArgument("Unknown option for this command: \(unknown)")
        }
    }
}

private struct RawWindow {
    let number: Int?
    let pid: Int32
    let ownerName: String?
    let layer: Int
    let bounds: RectValue
    let alpha: Double?
    let isOnScreen: Bool?
    let sharingState: Int?
    let title: String?
    let order: Int
}

private enum WindowCapture {
    static func rawWindows() throws -> [RawWindow] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            throw ProbeError.captureFailed("CGWindowListCopyWindowInfo returned no window metadata")
        }

        return dictionaries.enumerated().compactMap { order, dictionary in
            guard
                let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }
            return RawWindow(
                number: WindowNumberMetadataParser.parse(
                    dictionary[kCGWindowNumber as String] as? NSNumber
                ),
                pid: pid,
                ownerName: dictionary[kCGWindowOwnerName as String] as? String,
                layer: layer,
                bounds: RectValue(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                ),
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                isOnScreen: (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
                sharingState: (dictionary[kCGWindowSharingState as String] as? NSNumber)?.intValue,
                title: dictionary[kCGWindowName as String] as? String,
                order: order
            )
        }
    }

    static func codexWindows() throws -> [WindowSnapshot] {
        let bundleIDs = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
            ($0.processIdentifier, $0.bundleIdentifier)
        })
        return try rawWindows().compactMap { window in
            let bundleID = bundleIDs[window.pid] ?? nil
            guard bundleID == codexBundleID else { return nil }
            return WindowSnapshot(
                windowNumber: window.number,
                ownerPID: window.pid,
                resolvedBundleID: bundleID,
                ownerName: window.ownerName,
                layer: window.layer,
                bounds: window.bounds,
                alpha: window.alpha,
                isOnScreen: window.isOnScreen,
                sharingState: window.sharingState,
                title: window.title,
                order: window.order
            )
        }
    }

    @MainActor
    static func screens() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            let cg = CGDisplayBounds(id)
            return DisplayGeometry(
                id: id,
                cgFrame: RectValue(x: cg.minX, y: cg.minY, width: cg.width, height: cg.height),
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

private enum DiscriminatorDerivation {
    private static func separatingRange(
        around value: Double,
        competitorValues: [Double],
        evidenceLimit: Double
    ) -> NumericRange {
        let lowerNeighbor = competitorValues.filter { $0 < value }.max()
        let upperNeighbor = competitorValues.filter { $0 > value }.min()
        return NumericRange(
            minimum: lowerNeighbor.map { ($0 + value) / 2 } ?? 1,
            maximum: upperNeighbor.map { ($0 + value) / 2 } ?? max(value, evidenceLimit)
        )
    }

    static func derive(
        hidden: SnapshotDocument,
        visible: SnapshotDocument,
        excluded: [SnapshotDocument],
        axDocument: AXSnapshotDocument?,
        axSource: String?
    ) throws -> PetDiscriminator {
        let visibleWindows = visible.windows.filter {
            $0.resolvedBundleID == codexBundleID
                && $0.layer == 3
                && $0.isOnScreen == true
                && $0.bounds.area > 0
        }
        let evidenceStates = [hidden] + excluded
        let viable = visibleWindows.compactMap { window in
            makeRule(
                candidate: window,
                hidden: hidden,
                visible: visible,
                excluded: excluded,
                evidenceStates: evidenceStates,
                axRequirement: nil
            )
        }

        if axDocument == nil, axSource == nil {
            if viable.count == 1, let result = viable.first {
                return result
            }
            throw ProbeError.ambiguousDiscriminator(
                "CG metadata produced \(viable.count) evidence-derived discriminator(s); expected exactly one. Supply trusted evidence with --ax-tree <file>."
            )
        }
        guard let axDocument, let axSource else {
            throw ProbeError.ambiguousDiscriminator(
                "AX-assisted derivation requires both an AX document and its source path."
            )
        }
        let predicate = AXWindowStructuralPredicate.rebornObserved
        let selection = try AXEvidenceValidator.selectUniqueWindow(
            in: axDocument,
            predicate: predicate
        )
        let labeledCandidate = try AXEvidenceValidator.correlate(
            selection: selection,
            with: visibleWindows,
            expectedLayer: 3,
            screens: visible.screens
        )
        let requirement = AXRequirement(
            predicate: predicate,
            evidence: AXRequirementEvidence(
                source: URL(fileURLWithPath: axSource).lastPathComponent,
                observedPID: selection.pid,
                observedBounds: selection.bounds,
                observedLayer: labeledCandidate.layer,
                coordinateSpace: selection.coordinateSpace,
                successfulNotifications: predicate.requiredWindowNotifications.sorted()
            )
        )
        guard let result = makeRule(
            candidate: labeledCandidate,
            hidden: hidden,
            visible: visible,
            excluded: excluded,
            evidenceStates: evidenceStates,
            axRequirement: requirement
        ) else {
            throw ProbeError.ambiguousDiscriminator(
                "AX labeled the pet window, but the resulting CG rule did not match exactly one visible window and zero hidden/excluded windows."
            )
        }
        return result
    }

    private static func makeRule(
        candidate window: WindowSnapshot,
        hidden: SnapshotDocument,
        visible: SnapshotDocument,
        excluded: [SnapshotDocument],
        evidenceStates: [SnapshotDocument],
        axRequirement: AXRequirement?
    ) -> PetDiscriminator? {
        let everyState = [visible] + evidenceStates
        let competitors = everyState.flatMap(\.windows).filter {
            $0.resolvedBundleID == codexBundleID
                && $0.layer == window.layer
                && !($0.order == window.order && $0.bounds == window.bounds)
        }
        let maximumScreenWidth = everyState.flatMap(\.screens).map(\.cgFrame.width).max()
            ?? window.bounds.width
        let maximumScreenHeight = everyState.flatMap(\.screens).map(\.cgFrame.height).max()
            ?? window.bounds.height
        let width = separatingRange(
            around: window.bounds.width,
            competitorValues: competitors.map(\.bounds.width),
            evidenceLimit: maximumScreenWidth
        )
        let height = separatingRange(
            around: window.bounds.height,
            competitorValues: competitors.map(\.bounds.height),
            evidenceLimit: maximumScreenHeight
        )
        let nearbyOrders = competitors.filter {
            width.contains($0.bounds.width) && height.contains($0.bounds.height)
        }.map(\.order)
        let nextLowerWindow = nearbyOrders.filter { $0 > window.order }.min()
        let maximumEvidenceOrder = everyState.flatMap(\.windows).map(\.order).max()
            ?? window.order
        let rule = PetDiscriminator(
            schemaVersion: 1,
            resolvedBundleID: codexBundleID,
            layer: window.layer,
            width: width,
            height: height,
            maximumOrder: nextLowerWindow.map { $0 - 1 } ?? maximumEvidenceOrder,
            requireOnScreen: true,
            requiresAX: axRequirement != nil,
            axRequirement: axRequirement,
            evidence: DiscriminatorEvidence(
                hiddenState: hidden.state,
                visibleState: visible.state,
                excludedStates: excluded.map(\.state).sorted(),
                visibleCandidateBounds: window.bounds,
                visibleCandidateOrder: window.order
            )
        )
        guard visible.windows.filter(rule.matches).count == 1 else { return nil }
        guard evidenceStates.allSatisfy({ $0.windows.filter(rule.matches).isEmpty }) else { return nil }
        return rule
    }
}

@MainActor
private final class TrackingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 14, height: 14),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = NSColor.systemPink
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
}

private func monotonicSeconds() -> Double {
    ProcessInfo.processInfo.systemUptime
}

private func processCPUSeconds() -> Double {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

private final class AXMovementSignal: @unchecked Sendable {
    struct Event {
        let notification: String
        let time: Double
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(notification: String) {
        lock.lock()
        events.append(Event(notification: notification, time: monotonicSeconds()))
        lock.unlock()
    }

    func consume() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }
}

private func trackingAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<AXMovementSignal>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .record(notification: notification as String)
}

@MainActor
private final class AXLiveResolver {
    private struct LiveCandidate {
        let element: AXUIElement
        let selection: AXWindowSelection
    }

    private let requirement: AXRequirement
    private let signal = AXMovementSignal()
    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var runLoopSource: CFRunLoopSource?
    private(set) var notificationsReliable = false

    init(requirement: AXRequirement) throws {
        guard AXIsProcessTrusted() else {
            throw AXEvidenceError.notTrusted
        }
        guard requirement.predicate == .rebornObserved else {
            throw AXEvidenceError.predicateMismatch
        }
        self.requirement = requirement
    }

    func resolve(
        cgCandidates: [WindowSnapshot],
        absenceGuardCandidates: [WindowSnapshot],
        expectedLayer: Int,
        screens: [DisplayGeometry]
    ) throws -> WindowSnapshot? {
        guard AXIsProcessTrusted() else {
            throw AXEvidenceError.notTrusted
        }
        let candidates = try liveCandidates()
        guard candidates.count <= 1 else {
            throw AXEvidenceError.candidateCount(candidates.count)
        }
        guard let candidate = candidates.first else {
            stopObserving()
            guard absenceGuardCandidates.isEmpty else {
                throw AXEvidenceError.correlationCount(absenceGuardCandidates.count)
            }
            return nil
        }
        startObservingIfNeeded(candidate.element, pid: candidate.selection.pid)
        return try AXEvidenceValidator.correlate(
            selection: candidate.selection,
            with: cgCandidates,
            expectedLayer: expectedLayer,
            screens: screens
        )
    }

    func consumeEvents() -> [AXMovementSignal.Event] {
        signal.consume()
    }

    func stop() {
        stopObserving()
    }

    private func liveCandidates() throws -> [LiveCandidate] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == codexBundleID
        }
        guard !applications.isEmpty else {
            throw ProbeError.captureFailed("AX tracking found no running \(codexBundleID) process")
        }

        var result: [LiveCandidate] = []
        for application in applications {
            let pid = application.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let windows = try requiredElements(
                appElement,
                attribute: kAXWindowsAttribute as CFString
            )
            for window in windows {
                guard try liveWindowMatches(window) else { continue }
                guard let bounds = AXCapture.bounds(window) else {
                    throw AXEvidenceError.missingBounds
                }
                result.append(LiveCandidate(
                    element: window,
                    selection: AXWindowSelection(
                        pid: pid,
                        bounds: bounds,
                        coordinateSpace: .cgGlobalTopLeft
                    )
                ))
            }
        }
        return result
    }

    private func liveWindowMatches(
        _ window: AXUIElement,
        descendantLimit: Int = 512
    ) throws -> Bool {
        let predicate = requirement.predicate
        guard try requiredString(
            window,
            attribute: kAXRoleAttribute as CFString
        ) == predicate.role,
        try requiredOptionalString(
            window,
            attribute: kAXSubroleAttribute as CFString
        ) == predicate.subrole else {
            return false
        }

        var budget = AXTraversalBudget(limit: descendantLimit)
        var queue = try boundedChildren(window, budget: &budget)
        var index = 0
        while index < queue.count {
            let element = queue[index]
            index += 1
            _ = try requiredString(
                element,
                attribute: kAXRoleAttribute as CFString
            )
            if let subrole = try requiredOptionalString(
                element,
                attribute: kAXSubroleAttribute as CFString
            ), predicate.forbiddenDescendantSubroles.contains(subrole) {
                return false
            }
            queue.append(contentsOf: try boundedChildren(element, budget: &budget))
        }
        return true
    }

    private func boundedChildren(
        _ element: AXUIElement,
        budget: inout AXTraversalBudget
    ) throws -> [AXUIElement] {
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
        let boundedCount = try AXBoundedChildCountPolicy.reserve(
            status: status,
            reportedCount: Int(count),
            budget: &budget
        )
        guard boundedCount > 0 else { return [] }
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
            throw AXEvidenceError.attributeReadFailed(attribute as String)
        }
        return result
    }

    private func requiredString(
        _ element: AXUIElement,
        attribute: CFString
    ) throws -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let result = value as? String else {
            throw AXEvidenceError.attributeReadFailed(attribute as String)
        }
        return result
    }

    private func requiredOptionalString(
        _ element: AXUIElement,
        attribute: CFString
    ) throws -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        // AX explicitly reports noValue for a valid optional attribute with no value.
        // All other non-success results are structural read failures.
        if error == .noValue {
            return nil
        }
        guard error == .success else {
            throw AXEvidenceError.attributeReadFailed(attribute as String)
        }
        guard value == nil || value is String else {
            throw AXEvidenceError.attributeReadFailed(attribute as String)
        }
        return value as? String
    }

    private func requiredElements(
        _ element: AXUIElement,
        attribute: CFString
    ) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        // noValue is the complete leaf case; unsupported/invalid reads fail closed.
        if error == .noValue {
            return []
        }
        guard error == .success, let result = value as? [AXUIElement] else {
            throw AXEvidenceError.attributeReadFailed(attribute as String)
        }
        return result
    }

    private func startObservingIfNeeded(_ element: AXUIElement, pid: pid_t) {
        if let observedElement, CFEqual(observedElement, element) {
            return
        }
        stopObserving()

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, trackingAXObserverCallback, &newObserver) == .success,
              let newObserver else {
            notificationsReliable = false
            return
        }
        let refcon = Unmanaged.passUnretained(signal).toOpaque()
        var registered: [String] = []
        for notification in requirement.predicate.requiredWindowNotifications {
            let error = AXObserverAddNotification(
                newObserver,
                element,
                notification as CFString,
                refcon
            )
            guard error == .success else {
                for prior in registered {
                    AXObserverRemoveNotification(newObserver, element, prior as CFString)
                }
                notificationsReliable = false
                return
            }
            registered.append(notification)
        }

        let source = AXObserverGetRunLoopSource(newObserver)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        observer = newObserver
        observedElement = element
        runLoopSource = source
        notificationsReliable = true
    }

    private func stopObserving() {
        if let observer, let observedElement {
            for notification in requirement.predicate.requiredWindowNotifications {
                AXObserverRemoveNotification(observer, observedElement, notification as CFString)
            }
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        }
        observer = nil
        observedElement = nil
        runLoopSource = nil
        notificationsReliable = false
    }
}

@MainActor
private func runTracking(
    scenario: String,
    duration: Double,
    showPanel: Bool,
    discriminator: PetDiscriminator
) throws -> TrackMetrics {
    let panel = showPanel ? TrackingPanel() : nil
    let axResolver: AXLiveResolver?
    if discriminator.requiresAX {
        guard let requirement = discriminator.axRequirement else {
            throw AXEvidenceError.missingRequirement
        }
        axResolver = try AXLiveResolver(requirement: requirement)
    } else {
        axResolver = nil
    }
    defer { axResolver?.stop() }
    let expectedAbsent = scenario.lowercased().contains("hidden")
    let start = monotonicSeconds()
    var previousWall = start
    var previousCPU = processCPUSeconds()
    var previousBounds: RectValue?
    var highRateUntil = start
    var sampleCount = 0
    var minimumCount = Int.max
    var maximumCount = 0
    var countHistogram: [String: Int] = [:]
    var movementLatencies: [Double] = []
    var followLatencies: [Double] = []
    var panelUpdateLatencies: [Double] = []
    var idleCPU = 0.0
    var idleWall = 0.0
    var movingCPU = 0.0
    var movingWall = 0.0
    var panelAboveEveryTime = showPanel
    var residueDetected = false
    var screenIDs = Set<UInt32>()
    var petLayer: Int? = discriminator.layer
    var transitions: [VisibilityTransition] = []
    var previousPresent: Bool?
    var sawReliableAXNotifications = false

    while monotonicSeconds() - start < duration {
        let sampleStarted = monotonicSeconds()
        let axEvents = axResolver?.consumeEvents() ?? []
        let movementEvents = axEvents.filter {
            $0.notification == "AXMoved" || $0.notification == "AXResized"
        }
        let axMovement = !movementEvents.isEmpty
        if axMovement {
            movementLatencies.append(contentsOf: movementEvents.map {
                max(0, sampleStarted - $0.time) * 1_000
            })
            highRateUntil = sampleStarted + 0.5
        }
        let windows = try WindowCapture.codexWindows()
        let screens = WindowCapture.screens()
        let orderedMetadataCandidates = windows.filter(discriminator.matches)
        let metadataCandidates = windows.filter {
            discriminator.requiresAX
                ? discriminator.matchesAXEnvelope($0)
                : discriminator.matches($0)
        }
        let candidates: [WindowSnapshot]
        if let axResolver {
            if let correlated = try axResolver.resolve(
                cgCandidates: metadataCandidates,
                absenceGuardCandidates: orderedMetadataCandidates,
                expectedLayer: discriminator.layer,
                screens: screens
            ) {
                candidates = [correlated]
            } else {
                candidates = []
            }
            sawReliableAXNotifications = sawReliableAXNotifications
                || axResolver.notificationsReliable
        } else {
            candidates = metadataCandidates
        }
        let present = candidates.count == 1
        minimumCount = min(minimumCount, candidates.count)
        maximumCount = max(maximumCount, candidates.count)
        countHistogram[String(candidates.count), default: 0] += 1
        sampleCount += 1

        if previousPresent != present {
            transitions.append(VisibilityTransition(
                elapsedSeconds: sampleStarted - start,
                candidateCount: candidates.count,
                event: present ? "candidate-visible" : "candidate-absent"
            ))
            previousPresent = present
        }

        var moved = axMovement
        if let candidate = candidates.first, candidates.count == 1 {
            petLayer = candidate.layer
            let boundsMoved = previousBounds.map { $0 != candidate.bounds } ?? false
            if boundsMoved && !axMovement {
                movementLatencies.append((sampleStarted - previousWall) * 1_000)
                highRateUntil = sampleStarted + 0.5
            }
            moved = moved || boundsMoved
            previousBounds = candidate.bounds

            if let panel {
                if let converted = try? CoordinateConverter.convert(
                    cgWindowBounds: candidate.bounds,
                    screens: screens
                ) {
                    let panelUpdateStarted = monotonicSeconds()
                    screenIDs.insert(converted.screenID)
                    panel.level = NSWindow.Level(rawValue: candidate.layer + 1)
                    panel.setFrameOrigin(NSPoint(
                        x: converted.appKitBounds.x,
                        y: converted.appKitBounds.maxY - panel.frame.height
                    ))
                    panel.orderFrontRegardless()
                    panel.displayIfNeeded()
                    let panelCommitted = monotonicSeconds()
                    panelUpdateLatencies.append(
                        max(0, panelCommitted - panelUpdateStarted) * 1_000
                    )
                    let followOrigins = FollowLatencyTiming.origins(
                        pollStartedAt: sampleStarted,
                        axEventTimestamps: movementEvents.map(\.time),
                        boundsMoved: boundsMoved
                    )
                    followLatencies.append(contentsOf: FollowLatencyTiming.milliseconds(
                        origins: followOrigins,
                        committedAt: panelCommitted
                    ))

                    let raw = try WindowCapture.rawWindows()
                    let ordering = raw.map {
                        WindowOrderingRecord(
                            windowNumber: $0.number,
                            ownerPID: $0.pid,
                            layer: $0.layer,
                            bounds: $0.bounds,
                            order: $0.order
                        )
                    }
                    let actualAbove = PanelOrderingValidator.isPanelAbove(
                        panelWindowNumber: panel.windowNumber,
                        candidate: WindowStableIdentity(window: candidate),
                        windows: ordering
                    )
                    panelAboveEveryTime = panelAboveEveryTime
                        && actualAbove
                        && panel.level.rawValue > candidate.layer
                } else {
                    panel.orderOut(nil)
                    panelAboveEveryTime = false
                }
            }
        } else {
            previousBounds = nil
            if let panel {
                panel.orderOut(nil)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
                let stillVisible = try WindowCapture.rawWindows().contains {
                    $0.number == Optional(panel.windowNumber) && $0.isOnScreen == true
                }
                residueDetected = residueDetected || stillVisible
            }
        }

        let now = monotonicSeconds()
        let cpuNow = processCPUSeconds()
        let wallDelta = max(0, now - previousWall)
        let cpuDelta = max(0, cpuNow - previousCPU)
        if moved {
            movingWall += wallDelta
            movingCPU += cpuDelta
        } else {
            idleWall += wallDelta
            idleCPU += cpuDelta
        }
        previousWall = now
        previousCPU = cpuNow

        let interval = now < highRateUntil ? (1.0 / 60.0) : 0.1
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }
    panel?.orderOut(nil)

    let isSpaceScenario = scenario.lowercased().contains("space")
    let stable: Bool
    if expectedAbsent {
        stable = maximumCount == 0
    } else if isSpaceScenario {
        stable = maximumCount == 1
    } else {
        stable = minimumCount == 1 && maximumCount == 1
    }
    return TrackMetrics(
        schemaVersion: 1,
        scenario: scenario,
        requiresAX: discriminator.requiresAX,
        axNotificationsReliable: discriminator.requiresAX ? sawReliableAXNotifications : nil,
        panelEnabled: showPanel,
        durationSeconds: duration,
        sampleCount: sampleCount,
        candidateCountMinimum: minimumCount == Int.max ? 0 : minimumCount,
        candidateCountMaximum: maximumCount,
        candidateCountHistogram: countHistogram,
        stableCandidate: stable,
        maxMovementDetectionMs: movementLatencies.max(),
        maxFollowLatencyMs: followLatencies.max(),
        maxPanelUpdateMs: panelUpdateLatencies.max(),
        idleCPUSeconds: idleCPU,
        idleWallSeconds: idleWall,
        movingCPUSeconds: movingCPU,
        movingWallSeconds: movingWall,
        idleCPUPercent: idleWall > 0 ? idleCPU / idleWall * 100 : nil,
        movingCPUPercent: movingWall > 0 ? movingCPU / movingWall * 100 : nil,
        panelAbovePet: expectedAbsent ? !residueDetected : panelAboveEveryTime,
        panelResidueDetected: residueDetected,
        screenIDs: screenIDs.sorted(),
        petLayer: petLayer,
        visibilityTransitions: transitions
    )
}

private let axObserverCallback: AXObserverCallback = { _, _, _, _ in }

private func accessibilityIsTrusted(mode: AXTrustCheckMode) -> Bool {
    switch mode {
    case .passive:
        return AXIsProcessTrusted()
    case .prompt:
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
private enum AXCapture {
    private struct AttributeRead<Value> {
        let value: Value
        let succeeded: Bool
    }

    private final class MutableNode {
        let element: AXUIElement
        var role: AttributeRead<String?>?
        var subrole: AttributeRead<String?>?
        var identifier: String?
        var bounds: RectValue?
        var childRead: AttributeRead<[AXUIElement]>?
        var children: [MutableNode] = []

        init(element: AXUIElement) {
            self.element = element
        }

        func snapshot() -> AXNodeSnapshot {
            let capturedChildren = children.map { $0.snapshot() }
            let role = role ?? AttributeRead(value: nil, succeeded: false)
            let subrole = subrole ?? AttributeRead(value: nil, succeeded: false)
            let childRead = childRead ?? AttributeRead(value: [], succeeded: false)
            let complete = role.succeeded
                && subrole.succeeded
                && childRead.succeeded
                && capturedChildren.count == childRead.value.count
                && capturedChildren.allSatisfy(\.childrenComplete)
            return AXNodeSnapshot(
                role: role.value,
                subrole: subrole.value,
                identifier: identifier,
                bounds: bounds,
                childCount: childRead.value.count,
                children: capturedChildren,
                roleReadSucceeded: role.succeeded,
                subroleReadSucceeded: subrole.succeeded,
                childrenReadSucceeded: childRead.succeeded,
                childrenComplete: complete
            )
        }
    }

    static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        stringRead(element, attribute).value
    }

    private static func stringRead(
        _ element: AXUIElement,
        _ attribute: CFString,
        allowNoValue: Bool = true
    ) -> AttributeRead<String?> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        if allowNoValue, error == .noValue {
            return AttributeRead(value: nil, succeeded: true)
        }
        guard error == .success, value == nil || value is String else {
            return AttributeRead(value: nil, succeeded: false)
        }
        return AttributeRead(value: value as? String, succeeded: true)
    }

    static func bounds(_ element: AXUIElement) -> RectValue? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return RectValue(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        elementsRead(element, attribute: attribute).value
    }

    private static func elementsRead(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AttributeRead<[AXUIElement]> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        // noValue is recorded as an explicit, successfully-read empty child list.
        if error == .noValue {
            return AttributeRead(value: [], succeeded: true)
        }
        guard error == .success, let elements = value as? [AXUIElement] else {
            return AttributeRead(value: [], succeeded: false)
        }
        return AttributeRead(value: elements, succeeded: true)
    }

    static func node(
        _ element: AXUIElement,
        descendantLimit: Int = 512
    ) -> AXNodeSnapshot {
        let root = MutableNode(element: element)
        var queue = [root]
        var index = 0
        var allocatedDescendants = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            current.role = stringRead(
                current.element,
                kAXRoleAttribute as CFString,
                allowNoValue: false
            )
            current.subrole = stringRead(
                current.element,
                kAXSubroleAttribute as CFString
            )
            current.identifier = string(
                current.element,
                kAXIdentifierAttribute as CFString
            )
            current.bounds = bounds(current.element)
            let childRead = elementsRead(
                current.element,
                attribute: kAXChildrenAttribute as CFString
            )
            current.childRead = childRead
            if childRead.succeeded {
                for child in childRead.value {
                    guard allocatedDescendants < descendantLimit else { break }
                    let captured = MutableNode(element: child)
                    current.children.append(captured)
                    queue.append(captured)
                    allocatedDescendants += 1
                }
            }
        }
        return root.snapshot()
    }

    static func process(pid: pid_t) -> AXProcessSnapshot {
        let app = AXUIElementCreateApplication(pid)
        let windowsRead = elementsRead(app, attribute: kAXWindowsAttribute as CFString)
        var observer: AXObserver?
        let observerError = AXObserverCreate(pid, axObserverCallback, &observer)
        var notificationResults: [AXNotificationProbe] = []
        if let observer {
            let targets: [(AXUIElement, String)] = [(app, kAXWindowCreatedNotification)]
                + windowsRead.value.flatMap { window in
                    [
                        (window, kAXUIElementDestroyedNotification),
                        (window, kAXMovedNotification),
                        (window, kAXResizedNotification),
                    ]
                }
            for (target, notification) in targets {
                let error = AXObserverAddNotification(observer, target, notification as CFString, nil)
                notificationResults.append(AXNotificationProbe(
                    targetRole: string(target, kAXRoleAttribute as CFString),
                    notification: notification as String,
                    errorCode: error.rawValue
                ))
                if error == .success {
                    AXObserverRemoveNotification(observer, target, notification as CFString)
                }
            }
        }
        let windows = windowsRead.value.map { node($0) }
        let appRole = stringRead(
            app,
            kAXRoleAttribute as CFString,
            allowNoValue: false
        )
        let appRoot = AXNodeSnapshot(
            role: appRole.value,
            subrole: nil,
            identifier: string(app, kAXIdentifierAttribute as CFString),
            bounds: bounds(app),
            childCount: windowsRead.value.count,
            children: windows,
            roleReadSucceeded: appRole.succeeded,
            subroleReadSucceeded: true,
            childrenReadSucceeded: windowsRead.succeeded,
            childrenComplete: windowsRead.succeeded
                && windows.count == windowsRead.value.count
                && windows.allSatisfy(\.childrenComplete)
        )
        return AXProcessSnapshot(
            pid: pid,
            bundleID: codexBundleID,
            observerCreationErrorCode: observerError.rawValue,
            notifications: notificationResults,
            tree: appRoot,
            windowsReadSucceeded: windowsRead.succeeded
        )
    }
}

private enum Evaluation {
    static let behaviorSnapshots = [
        "notification-open.json",
        "ordinary-space-switch.json",
        "fullscreen-space.json",
    ]
    static let requiredMetrics = [
        "dragging.json",
        "covered.json",
        "pet-hidden.json",
        "ordinary-space-switch.json",
        "fullscreen-space.json",
    ]

    static func evaluate(options: EvaluationOptions) -> GateResult {
        let fileManager = FileManager.default
        let snapshotURL = URL(fileURLWithPath: options.snapshotsDirectory)
        let metricsURL = URL(fileURLWithPath: options.metricsDirectory)
        var identificationFailures: [String] = []
        var snapshotDocuments: [String: SnapshotDocument] = [:]
        var existingSnapshotNames = Set<String>()
        var screenCountsBySnapshot: [String: Int] = [:]
        for name in EvaluationSnapshotPolicy.requiredStructuralSnapshots {
            let path = snapshotURL.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: path) else { continue }
            existingSnapshotNames.insert(name)
            do {
                let document = try ProbeJSON.read(SnapshotDocument.self, from: path)
                try PersistedArtifactValidator.validateSnapshot(
                    document,
                    expectedState: String(name.dropLast(".json".count))
                )
                snapshotDocuments[name] = document
                screenCountsBySnapshot[name] = document.screens.count
            } catch {
                identificationFailures.append("Could not validate \(name): \(error)")
            }
        }
        let secondaryName = EvaluationSnapshotPolicy.secondaryDisplaySnapshot
        if EvaluationSnapshotPolicy.requiredSnapshots(
            screenCountsBySnapshot: screenCountsBySnapshot
        ).contains(secondaryName) {
            let path = snapshotURL.appendingPathComponent(secondaryName).path
            if fileManager.fileExists(atPath: path) {
                existingSnapshotNames.insert(secondaryName)
                do {
                    let document = try ProbeJSON.read(SnapshotDocument.self, from: path)
                    try PersistedArtifactValidator.validateSnapshot(
                        document,
                        expectedState: "secondary-display"
                    )
                    snapshotDocuments[secondaryName] = document
                    screenCountsBySnapshot[secondaryName] = document.screens.count
                } catch {
                    identificationFailures.append(
                        "Could not validate \(secondaryName): \(error)"
                    )
                }
            }
        }
        let missingSnapshots = EvaluationSnapshotPolicy.missingSnapshots(
            existingNames: existingSnapshotNames,
            screenCountsBySnapshot: screenCountsBySnapshot
        )
        let missingMetrics = requiredMetrics.filter {
            !fileManager.fileExists(atPath: metricsURL.appendingPathComponent($0).path)
        }
        let discriminatorPath = snapshotURL.appendingPathComponent("discriminator.json").path
        let discriminator: PetDiscriminator?
        do {
            let decoded = try ProbeJSON.read(PetDiscriminator.self, from: discriminatorPath)
            try PersistedArtifactValidator.validateDiscriminator(decoded)
            discriminator = decoded
        } catch {
            identificationFailures.append("Missing or invalid discriminator.json: \(error)")
            discriminator = nil
        }
        var performanceFailures = missingMetrics.map { "Missing performance metrics: \($0)" }

        if let discriminator {
            do {
                let axDocument: AXSnapshotDocument?
                if discriminator.requiresAX {
                    guard let requirement = discriminator.axRequirement else {
                        throw AXEvidenceError.missingRequirement
                    }
                    let path = snapshotURL.appendingPathComponent(requirement.evidence.source).path
                    let decoded = try ProbeJSON.read(AXSnapshotDocument.self, from: path)
                    try PersistedArtifactValidator.validateAXDocument(decoded)
                    axDocument = decoded
                } else {
                    axDocument = nil
                }
                if discriminator.requiresAX {
                    guard let visible = snapshotDocuments["pet-visible.json"] else {
                        throw AXEvidenceError.incompleteTraversal
                    }
                    _ = try AXGateValidator.validate(
                        discriminator: discriminator,
                        axDocument: axDocument,
                        visibleWindows: visible.windows,
                        screens: visible.screens
                    )
                }
            } catch {
                identificationFailures.append("AX discriminator validation failed: \(error)")
            }

            let expectedOne = ["pet-visible.json", "pet-moved.json", "pet-resized.json"]
            let expectedZero = ["pet-hidden.json", "small-codex-window.json"]
            for name in expectedOne where !missingSnapshots.contains(name) {
                guard let document = snapshotDocuments[name] else { continue }
                let count = document.windows.filter {
                    discriminator.requiresAX
                        ? discriminator.matchesAXEnvelope($0)
                        : discriminator.matches($0)
                }.count
                if count != 1 {
                    identificationFailures.append("\(name) matched \(count) candidates; expected 1")
                }
            }
            for name in expectedZero where !missingSnapshots.contains(name) {
                guard let document = snapshotDocuments[name] else { continue }
                let count = document.windows.filter(discriminator.matches).count
                if count != 0 {
                    identificationFailures.append("\(name) matched \(count) candidates; expected 0")
                }
            }

            if let document = snapshotDocuments[secondaryName] {
                let count = document.windows.filter {
                    discriminator.requiresAX
                        ? discriminator.matchesAXEnvelope($0)
                        : discriminator.matches($0)
                }.count
                if count != 1 {
                    identificationFailures.append(
                        "\(secondaryName) matched \(count) candidates; expected 1"
                    )
                }
            }
        }

        let behaviorEvidence = behaviorSnapshots.map { name -> BehaviorEvidenceObservation in
            guard existingSnapshotNames.contains(name) else {
                return BehaviorEvidenceObservation(snapshot: name, available: false, candidateCount: nil)
            }
            guard let document = snapshotDocuments[name] else {
                return BehaviorEvidenceObservation(snapshot: name, available: true, candidateCount: nil)
            }
            let count = discriminator.map { rule in
                document.windows.filter {
                    rule.requiresAX ? rule.matchesAXEnvelope($0) : rule.matches($0)
                }.count
            }
            return BehaviorEvidenceObservation(snapshot: name, available: true, candidateCount: count)
        }

        var metrics: [TrackMetrics] = []
        for name in requiredMetrics where !missingMetrics.contains(name) {
            let path = metricsURL.appendingPathComponent(name).path
            guard let discriminator else {
                performanceFailures.append(
                    "\(name): cannot validate provenance without a valid discriminator"
                )
                continue
            }
            let expectedScenario = String(name.dropLast(".json".count))
            do {
                let metric = try ProbeJSON.read(TrackMetrics.self, from: path)
                let provenanceFailures = TrackMetricsValidator.failures(
                    metric,
                    expectation: TrackMetricsExpectation(
                        scenario: expectedScenario,
                        minimumDurationSeconds: expectedScenario == "dragging" ? 30 : 15,
                        requiresPanel: true,
                        requiresAX: discriminator.requiresAX,
                        petLayer: discriminator.layer
                    )
                )
                if provenanceFailures.isEmpty {
                    metrics.append(metric)
                } else {
                    performanceFailures.append(contentsOf: provenanceFailures.map {
                        "\(name): \($0)"
                    })
                }
            } catch {
                performanceFailures.append("Could not validate metrics file \(name): \(error)")
            }
        }
        for metric in metrics {
            if !metric.stableCandidate {
                performanceFailures.append("\(metric.scenario): candidate was not stable")
            }
            if metric.panelResidueDetected {
                performanceFailures.append("\(metric.scenario): panel residue was detected")
            }
            if !metric.panelAbovePet {
                performanceFailures.append("\(metric.scenario): panel-above-pet check failed")
            }
            if let latency = metric.maxMovementDetectionMs,
               !PerformanceAcceptancePolicy.acceptsMovementDetection(milliseconds: latency) {
                performanceFailures.append(
                    "\(metric.scenario): movement detection \(latency) ms exceeded "
                        + "\(PerformanceAcceptancePolicy.maximumMovementDetectionMilliseconds) ms"
                )
            }
            if let latency = metric.maxFollowLatencyMs,
               !PerformanceAcceptancePolicy.acceptsFollowLatency(milliseconds: latency) {
                performanceFailures.append(
                    "\(metric.scenario): follow latency \(latency) ms exceeded "
                        + "\(PerformanceAcceptancePolicy.maximumFollowLatencyMilliseconds) ms"
                )
            }
            if let cpu = metric.idleCPUPercent,
               !PerformanceAcceptancePolicy.acceptsIdleCPU(percent: cpu) {
                performanceFailures.append(
                    "\(metric.scenario): idle CPU \(cpu)% was not below "
                        + "\(PerformanceAcceptancePolicy.maximumExclusiveIdleCPUPercent)%"
                )
            }
            if let cpu = metric.movingCPUPercent,
               !PerformanceAcceptancePolicy.acceptsMovingCPU(percent: cpu) {
                performanceFailures.append(
                    "\(metric.scenario): moving CPU \(cpu)% was not below "
                        + "\(PerformanceAcceptancePolicy.maximumExclusiveMovingCPUPercent)%"
                )
            }
        }

        let maxMovement = metrics.compactMap(\.maxMovementDetectionMs).max()
        let maxFollow = metrics.compactMap(\.maxFollowLatencyMs).max()
        let maxIdleCPU = metrics.compactMap(\.idleCPUPercent).max()
        let maxMovingCPU = metrics.compactMap(\.movingCPUPercent).max()
        if maxMovement == nil {
            performanceFailures.append("No movement-detection measurement was recorded")
        }
        if maxFollow == nil {
            performanceFailures.append("No follow-latency measurement was recorded")
        }
        if maxIdleCPU == nil {
            performanceFailures.append("No idle CPU measurement was recorded")
        }
        if maxMovingCPU == nil {
            performanceFailures.append("No moving CPU measurement was recorded")
        }

        let requiresAX = discriminator?.requiresAX ?? false
        let identificationPassed = missingSnapshots.isEmpty
            && discriminator != nil
            && identificationFailures.isEmpty
        let performanceVerified = missingMetrics.isEmpty
            && metrics.count == requiredMetrics.count
            && performanceFailures.isEmpty
        let decision = GateDecisionPolicy.decide(
            identificationPassed: identificationPassed,
            performanceVerified: performanceVerified,
            deferPerformance: options.deferPerformance,
            deferralNote: options.deferralNote
        )
        let failures = identificationFailures
            + (options.deferPerformance ? [] : performanceFailures)
        let warnings = options.deferPerformance ? performanceFailures : []
        return GateResult(
            schemaVersion: 1,
            passed: decision.passed,
            identificationPassed: decision.identificationPassed,
            performanceVerified: decision.performanceVerified,
            performanceDeferred: decision.performanceDeferred,
            deferralNote: decision.deferralNote,
            requiresAX: requiresAX,
            petLayer: discriminator?.layer,
            discriminator: discriminator,
            maxMovementDetectionMs: maxMovement,
            maxFollowLatencyMs: maxFollow,
            idleCPUPercent: maxIdleCPU,
            movingCPUPercent: maxMovingCPU,
            missingSnapshots: missingSnapshots,
            missingMetrics: missingMetrics,
            failures: failures.sorted(),
            warnings: warnings.sorted(),
            behaviorEvidence: behaviorEvidence
        )
    }
}

@MainActor
private func run() throws {
    let rawArguments = CommandLine.arguments.dropFirst()
    guard let command = rawArguments.first else {
        throw ProbeError.usage("Usage: RebornWindowProbe <snapshot|derive|track|ax-snapshot|evaluate> [options]")
    }
    let commandArguments = rawArguments.dropFirst()
    let repeatableOptions: Set<String> = command == "derive" ? ["--exclude"] : []
    let parsed = try ParsedArguments(commandArguments, repeatableOptions: repeatableOptions)

    switch command {
    case "snapshot":
        try parsed.validate(allowedOptions: ["--state", "--output"])
        let state = try parsed.required("--state")
        let output = try parsed.required("--output")
        let document = SnapshotDocument(
            schemaVersion: 1,
            state: state,
            screens: WindowCapture.screens(),
            windows: try WindowCapture.codexWindows()
        )
        try PersistedArtifactValidator.validateSnapshot(document, expectedState: state)
        try ProbeJSON.write(document, to: output)
        print("snapshot state=\(state) windows=\(document.windows.count) output=\(output)")

    case "derive":
        try parsed.validate(
            allowedOptions: ["--hidden", "--visible", "--exclude", "--ax-tree", "--output"]
        )
        let hidden = try ProbeJSON.read(
            SnapshotDocument.self,
            from: parsed.required("--hidden")
        )
        try PersistedArtifactValidator.validateSnapshot(hidden, expectedState: "pet-hidden")
        let visible = try ProbeJSON.read(
            SnapshotDocument.self,
            from: parsed.required("--visible")
        )
        try PersistedArtifactValidator.validateSnapshot(visible, expectedState: "pet-visible")
        let excludedPaths = try parsed.repeatedValues(for: "--exclude", in: commandArguments)
        guard !excludedPaths.isEmpty else {
            throw ProbeError.invalidArgument("derive requires at least one --exclude <file>")
        }
        let excluded = try excludedPaths.map { path in
            let document = try ProbeJSON.read(SnapshotDocument.self, from: path)
            let expectedState = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
            try PersistedArtifactValidator.validateSnapshot(
                document,
                expectedState: expectedState
            )
            return document
        }
        let axSource = parsed.options["--ax-tree"]
        let axDocument = try axSource.map {
            let document = try ProbeJSON.read(AXSnapshotDocument.self, from: $0)
            try PersistedArtifactValidator.validateAXDocument(document)
            return document
        }
        let discriminator = try DiscriminatorDerivation.derive(
            hidden: hidden,
            visible: visible,
            excluded: excluded,
            axDocument: axDocument,
            axSource: axSource
        )
        try PersistedArtifactValidator.validateDiscriminator(discriminator)
        let output = try parsed.required("--output")
        try ProbeJSON.write(discriminator, to: output)
        print("derive candidates=1 layer=\(discriminator.layer) requiresAX=\(discriminator.requiresAX) output=\(output)")

    case "track":
        try parsed.validate(
            allowedOptions: ["--scenario", "--duration-seconds", "--discriminator", "--metrics-out"],
            allowedFlags: ["--panel"]
        )
        let scenario = try parsed.required("--scenario")
        let duration = try parsed.double("--duration-seconds")
        let discriminator = try ProbeJSON.read(
            PetDiscriminator.self,
            from: parsed.required("--discriminator")
        )
        try PersistedArtifactValidator.validateDiscriminator(discriminator)
        let metrics = try runTracking(
            scenario: scenario,
            duration: duration,
            showPanel: parsed.flags.contains("--panel"),
            discriminator: discriminator
        )
        let metricFailures = TrackMetricsValidator.failures(
            metrics,
            expectation: TrackMetricsExpectation(
                scenario: scenario,
                minimumDurationSeconds: duration,
                requiresPanel: parsed.flags.contains("--panel"),
                requiresAX: discriminator.requiresAX,
                petLayer: discriminator.layer
            )
        )
        guard metricFailures.isEmpty else {
            throw ProbeError.captureFailed(
                "Generated metrics failed validation: \(metricFailures.joined(separator: "; "))"
            )
        }
        let output = try parsed.required("--metrics-out")
        try ProbeJSON.write(metrics, to: output)
        print("track scenario=\(scenario) samples=\(metrics.sampleCount) stable=\(metrics.stableCandidate) output=\(output)")

    case "ax-snapshot":
        let options = try AXSnapshotOptions.parse(arguments: Array(commandArguments))
        let trustedForAccessibility = accessibilityIsTrusted(mode: options.trustCheckMode)
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == codexBundleID }
            .map(\.processIdentifier)
            .sorted()
        let document = AXSnapshotDocument(
            schemaVersion: 2,
            trustedForAccessibility: trustedForAccessibility,
            coordinateSpace: .cgGlobalTopLeft,
            processes: pids.map { AXCapture.process(pid: $0) }
        )
        try PersistedArtifactValidator.validateAXDocument(
            document,
            requireTrusted: false
        )
        try ProbeJSON.write(document, to: options.outputPath)
        print("ax-snapshot processes=\(document.processes.count) trusted=\(document.trustedForAccessibility) output=\(options.outputPath)")

    case "evaluate":
        let options = try EvaluationOptions.parse(arguments: Array(commandArguments))
        let result = Evaluation.evaluate(options: options)
        let gateExitCode = try GateOutputWriter.write(
            result,
            to: options.outputPath,
            passed: result.passed
        )
        print("evaluate passed=\(result.passed) identificationPassed=\(result.identificationPassed) performanceVerified=\(result.performanceVerified) performanceDeferred=\(result.performanceDeferred) failures=\(result.failures.count) output=\(options.outputPath)")
        guard gateExitCode == 0 else { throw ProbeError.gateFailed }

    default:
        throw ProbeError.usage("Unknown command '\(command)'. Expected snapshot, derive, track, ax-snapshot, or evaluate.")
    }
}

do {
    try MainActor.assumeIsolated {
        try run()
    }
} catch {
    FileHandle.standardError.write(Data("RebornWindowProbe error: \(error)\n".utf8))
    if case ProbeError.gateFailed = error {
        exit(GateProcessExit.code(passed: false))
    }
    exit(2)
}
