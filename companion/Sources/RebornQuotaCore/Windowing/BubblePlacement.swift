import Foundation

public struct SizeValue: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum BubbleSide: Equatable, Sendable {
    case above
    case below
}

public struct BubblePlacement: Equatable, Sendable {
    public let origin: PointValue
    public let side: BubbleSide

    public init(origin: PointValue, side: BubbleSide) {
        self.origin = origin
        self.side = side
    }
}

/// Local-coordinate geometry shared by the SwiftUI silhouette and deterministic
/// tests. SwiftUI's local Y axis grows downward, so an above-pet bubble points at
/// `maxY`, while a below-pet bubble points at `minY`.
public struct BubbleSilhouetteGeometry: Equatable, Sendable {
    public let body: RectValue
    public let arrowBaseY: Double
    public let arrowTipY: Double

    public init(body: RectValue, arrowBaseY: Double, arrowTipY: Double) {
        self.body = body
        self.arrowBaseY = arrowBaseY
        self.arrowTipY = arrowTipY
    }
}

public enum BubbleSilhouetteLayout {
    public static func geometry(
        side: BubbleSide,
        bounds: RectValue,
        arrowHeight: Double
    ) -> BubbleSilhouetteGeometry? {
        guard bounds.x.isFinite,
              bounds.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite,
              arrowHeight.isFinite,
              arrowHeight > 0,
              arrowHeight < bounds.height else {
            return nil
        }

        switch side {
        case .above:
            let body = RectValue(
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height - arrowHeight
            )
            return BubbleSilhouetteGeometry(
                body: body,
                arrowBaseY: body.maxY,
                arrowTipY: bounds.maxY
            )
        case .below:
            let body = RectValue(
                x: bounds.x,
                y: bounds.y + arrowHeight,
                width: bounds.width,
                height: bounds.height - arrowHeight
            )
            return BubbleSilhouetteGeometry(
                body: body,
                arrowBaseY: body.minY,
                arrowTipY: bounds.minY
            )
        }
    }
}

public enum BubbleSilhouetteHitRegion {
    public static func contains(
        _ point: PointValue,
        side: BubbleSide,
        bounds: RectValue,
        arrowWidth: Double,
        arrowHeight: Double,
        cornerRadius: Double
    ) -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              arrowWidth.isFinite,
              arrowWidth > 0,
              cornerRadius.isFinite,
              cornerRadius >= 0,
              let geometry = BubbleSilhouetteLayout.geometry(
                side: side,
                bounds: bounds,
                arrowHeight: arrowHeight
              ) else { return false }

        if roundedRectContains(point, rect: geometry.body, radius: cornerRadius) {
            return true
        }
        let halfWidth = min(arrowWidth, bounds.width) / 2
        return triangleContains(
            point,
            a: PointValue(x: bounds.x + bounds.width / 2 - halfWidth, y: geometry.arrowBaseY),
            b: PointValue(x: bounds.x + bounds.width / 2, y: geometry.arrowTipY),
            c: PointValue(x: bounds.x + bounds.width / 2 + halfWidth, y: geometry.arrowBaseY)
        )
    }

    private static func roundedRectContains(
        _ point: PointValue,
        rect: RectValue,
        radius: Double
    ) -> Bool {
        guard point.x >= rect.minX,
              point.x <= rect.maxX,
              point.y >= rect.minY,
              point.y <= rect.maxY else { return false }
        let radius = min(radius, rect.width / 2, rect.height / 2)
        if radius == 0
            || (point.x >= rect.minX + radius && point.x <= rect.maxX - radius)
            || (point.y >= rect.minY + radius && point.y <= rect.maxY - radius) {
            return true
        }
        let centerX = point.x < rect.minX + radius
            ? rect.minX + radius
            : rect.maxX - radius
        let centerY = point.y < rect.minY + radius
            ? rect.minY + radius
            : rect.maxY - radius
        let dx = point.x - centerX
        let dy = point.y - centerY
        return dx * dx + dy * dy <= radius * radius
    }

    private static func triangleContains(
        _ point: PointValue,
        a: PointValue,
        b: PointValue,
        c: PointValue
    ) -> Bool {
        func sign(_ p1: PointValue, _ p2: PointValue, _ p3: PointValue) -> Double {
            (p1.x - p3.x) * (p2.y - p3.y)
                - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(point, a, b)
        let d2 = sign(point, b, c)
        let d3 = sign(point, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }
}

public enum BubbleWindowHitClassification: Equatable, Sendable {
    case insideSilhouette
    case transparentPanelArea
    case outsidePanel
}

/// Converts AppKit global screen coordinates into the silhouette's SwiftUI-local,
/// top-down coordinate space before deciding WindowServer mouse pass-through.
public enum BubbleWindowHitPolicy {
    public static func classify(
        screenPoint: PointValue,
        panelFrame: RectValue,
        side: BubbleSide,
        arrowWidth: Double = 14,
        arrowHeight: Double = 7,
        cornerRadius: Double = 10
    ) -> BubbleWindowHitClassification {
        guard screenPoint.x.isFinite,
              screenPoint.y.isFinite,
              panelFrame.x.isFinite,
              panelFrame.y.isFinite,
              panelFrame.width.isFinite,
              panelFrame.height.isFinite,
              panelFrame.width > 0,
              panelFrame.height > 0,
              screenPoint.x >= panelFrame.minX,
              screenPoint.x <= panelFrame.maxX,
              screenPoint.y >= panelFrame.minY,
              screenPoint.y <= panelFrame.maxY else {
            return .outsidePanel
        }
        let local = PointValue(
            x: screenPoint.x - panelFrame.x,
            y: panelFrame.height - (screenPoint.y - panelFrame.y)
        )
        let localBounds = RectValue(
            x: 0,
            y: 0,
            width: panelFrame.width,
            height: panelFrame.height
        )
        return BubbleSilhouetteHitRegion.contains(
            local,
            side: side,
            bounds: localBounds,
            arrowWidth: arrowWidth,
            arrowHeight: arrowHeight,
            cornerRadius: cornerRadius
        ) ? .insideSilhouette : .transparentPanelArea
    }

    public static func shouldIgnoreMouseEvents(
        screenPoint: PointValue,
        panelFrame: RectValue,
        side: BubbleSide
    ) -> Bool {
        classify(
            screenPoint: screenPoint,
            panelFrame: panelFrame,
            side: side
        ) == .transparentPanelArea
    }
}

public enum QuotaPanelGeometry {
    public static func frame(
        expandedPlacement: BubblePlacement,
        expandedSize: SizeValue,
        currentSize: SizeValue
    ) -> RectValue? {
        guard expandedSize.width.isFinite,
              expandedSize.height.isFinite,
              currentSize.width.isFinite,
              currentSize.height.isFinite,
              expandedSize.width > 0,
              expandedSize.height > 0,
              currentSize.width > 0,
              currentSize.height > 0,
              currentSize.width <= expandedSize.width,
              currentSize.height <= expandedSize.height else { return nil }
        let x = expandedPlacement.origin.x
            + (expandedSize.width - currentSize.width) / 2
        let y: Double
        switch expandedPlacement.side {
        case .above:
            y = expandedPlacement.origin.y
        case .below:
            y = expandedPlacement.origin.y + expandedSize.height - currentSize.height
        }
        let result = RectValue(
            x: x,
            y: y,
            width: currentSize.width,
            height: currentSize.height
        )
        guard result.x.isFinite,
              result.y.isFinite,
              result.maxX.isFinite,
              result.maxY.isFinite else { return nil }
        return result
    }

    public static func safeLevel(
        petLayer: Int,
        floating: Int,
        screenSaver: Int
    ) -> Int {
        guard screenSaver > floating else { return floating }
        let maximum = screenSaver - 1
        let proposed = petLayer == Int.max ? maximum : petLayer + 1
        return min(max(proposed, floating), maximum)
    }
}

public struct BubblePlacementSessionDecision: Equatable, Sendable {
    public let placement: BubblePlacement
    public let contextChanged: Bool

    public init(placement: BubblePlacement, contextChanged: Bool) {
        self.placement = placement
        self.contextChanged = contextChanged
    }
}

public struct BubblePlacementSession: Equatable, Sendable {
    public private(set) var screenID: UInt32?
    public private(set) var screenVisibleFrame: RectValue?
    public private(set) var lockedSide: BubbleSide?

    public init() {}

    public mutating func update(
        petFrame: RectValue,
        screenID: UInt32,
        screenVisibleFrame: RectValue,
        expandedSize: SizeValue,
        gap: Double
    ) -> BubblePlacementSessionDecision? {
        let contextChanged = self.screenID != nil
            && (self.screenID != screenID || self.screenVisibleFrame != screenVisibleFrame)
        if contextChanged { lockedSide = nil }
        self.screenID = screenID
        self.screenVisibleFrame = screenVisibleFrame
        guard let placement = BubblePlacementEngine.choose(
            petFrame: petFrame,
            screenVisibleFrame: screenVisibleFrame,
            expandedSize: expandedSize,
            gap: gap,
            lockedSide: lockedSide
        ) else { return nil }
        lockedSide = placement.side
        return BubblePlacementSessionDecision(
            placement: placement,
            contextChanged: contextChanged
        )
    }

    public mutating func reset() {
        screenID = nil
        screenVisibleFrame = nil
        lockedSide = nil
    }
}

public enum BubblePlacementEngine {
    public static func choose(
        petFrame: RectValue,
        screenVisibleFrame: RectValue,
        expandedSize: SizeValue,
        gap: Double,
        lockedSide: BubbleSide?
    ) -> BubblePlacement? {
        guard valid(rect: petFrame),
              valid(rect: screenVisibleFrame),
              expandedSize.width.isFinite,
              expandedSize.height.isFinite,
              expandedSize.width > 0,
              expandedSize.height > 0,
              gap.isFinite,
              gap >= 0,
              expandedSize.width <= screenVisibleFrame.width,
              expandedSize.height <= screenVisibleFrame.height else {
            return nil
        }

        let centeredX = petFrame.x + (petFrame.width - expandedSize.width) / 2
        let rightmostOriginX = screenVisibleFrame.maxX - expandedSize.width
        guard centeredX.isFinite, rightmostOriginX.isFinite else { return nil }
        let originX = min(
            max(centeredX, screenVisibleFrame.minX),
            rightmostOriginX
        )
        let bubbleMaxX = originX + expandedSize.width
        guard originX.isFinite,
              bubbleMaxX.isFinite,
              originX >= screenVisibleFrame.minX,
              bubbleMaxX <= screenVisibleFrame.maxX else {
            return nil
        }

        func placement(on side: BubbleSide) -> BubblePlacement? {
            let originY: Double
            switch side {
            case .above:
                originY = petFrame.maxY + gap
            case .below:
                originY = petFrame.minY - gap - expandedSize.height
            }
            let bubbleMaxY = originY + expandedSize.height
            guard originY.isFinite,
                  bubbleMaxY.isFinite,
                  originY >= screenVisibleFrame.minY,
                  bubbleMaxY <= screenVisibleFrame.maxY else {
                return nil
            }
            return BubblePlacement(origin: PointValue(x: originX, y: originY), side: side)
        }

        if let lockedSide {
            return placement(on: lockedSide)
        }
        return placement(on: .above) ?? placement(on: .below)
    }

    private static func valid(rect: RectValue) -> Bool {
        rect.x.isFinite
            && rect.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.maxX.isFinite
            && rect.maxY.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
