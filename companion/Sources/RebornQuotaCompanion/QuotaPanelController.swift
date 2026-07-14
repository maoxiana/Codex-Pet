import AppKit
import RebornQuotaCore
import SwiftUI

private final class NonactivatingQuotaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuotaPanelController {
    private static let fixedSize = SizeValue(width: 200, height: 56)
    private static let gap: Double = 8

    private let panel: NonactivatingQuotaPanel
    private let hostingView: NSHostingView<QuotaBubbleView>
    private let formatter: QuotaPresentationFormatter
    private var presentation: QuotaPresentation
    private var currentPlacement: BubblePlacement?
    private var placementSession = BubblePlacementSession()

    init(initialState: QuotaDisplayState = .loading) {
        formatter = QuotaPresentationFormatter(
            calendar: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent,
            locale: .autoupdatingCurrent
        )
        presentation = formatter.format(initialState)

        panel = NonactivatingQuotaPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.isReleasedWhenClosed = false

        hostingView = NSHostingView(rootView: QuotaBubbleView(
            presentation: presentation,
            side: .above
        ))
        panel.contentView = hostingView
        refreshRootView()
    }

    func updateQuota(_ state: QuotaDisplayState) {
        presentation = formatter.format(state)
        refreshRootView()
    }

    func apply(_ update: PetWindowLocationUpdate) {
        switch update {
        case .hidden:
            hide()
        case .visible(let location):
            showOrMove(to: location)
        }
    }

    func shutdown() {
        hide()
        panel.orderOut(nil)
    }

    private func showOrMove(to location: LocatedPetWindow) {
        guard let decision = placementSession.update(
            petFrame: location.petFrame,
            screenID: location.screenID,
            screenVisibleFrame: location.screenVisibleFrame,
            expandedSize: Self.fixedSize,
            gap: Self.gap
        ) else {
            hide()
            return
        }
        if decision.contextChanged {
            panel.orderOut(nil)
        }
        let placement = decision.placement
        currentPlacement = placement
        panel.level = Self.safeWindowLevel(petLayer: location.petLayer)
        updatePanelFrame()
        refreshRootView()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        currentPlacement = nil
        placementSession.reset()
        panel.orderOut(nil)
        refreshRootView()
    }

    private func refreshRootView() {
        hostingView.rootView = QuotaBubbleView(
            presentation: presentation,
            side: currentPlacement?.side ?? .above
        )
    }

    private func updatePanelFrame() {
        guard let currentPlacement else { return }
        let frame = NSRect(
            x: currentPlacement.origin.x,
            y: currentPlacement.origin.y,
            width: Self.fixedSize.width,
            height: Self.fixedSize.height
        )
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
    }

    private static func safeWindowLevel(petLayer: Int) -> NSWindow.Level {
        let minimum = NSWindow.Level.floating.rawValue
        return NSWindow.Level(rawValue: QuotaPanelGeometry.safeLevel(
            petLayer: petLayer,
            floating: minimum,
            screenSaver: NSWindow.Level.screenSaver.rawValue
        ))
    }

}
