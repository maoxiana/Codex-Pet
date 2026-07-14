import Foundation

public struct PointValue: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RectValue: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }

    public func intersectionArea(with other: RectValue) -> Double {
        let overlapWidth = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let overlapHeight = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        return overlapWidth * overlapHeight
    }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public let windowNumber: Int?
    public let ownerPID: Int32
    public let resolvedBundleID: String?
    public let ownerName: String?
    public let layer: Int
    public let bounds: RectValue
    public let alpha: Double?
    public let isOnScreen: Bool?
    public let sharingState: Int?
    public let title: String?
    public let order: Int

    public init(
        windowNumber: Int? = nil,
        ownerPID: Int32,
        resolvedBundleID: String?,
        ownerName: String?,
        layer: Int,
        bounds: RectValue,
        alpha: Double?,
        isOnScreen: Bool?,
        sharingState: Int?,
        title: String?,
        order: Int
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.resolvedBundleID = resolvedBundleID
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
        self.title = title
        self.order = order
    }
}
