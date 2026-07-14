import Foundation

public struct DisplayGeometry: Codable, Equatable, Sendable {
    public let id: UInt32
    public let cgFrame: RectValue
    public let appKitFrame: RectValue
    public let appKitVisibleFrame: RectValue
    public let backingScaleFactor: Double

    public init(
        id: UInt32,
        cgFrame: RectValue,
        appKitFrame: RectValue,
        appKitVisibleFrame: RectValue,
        backingScaleFactor: Double
    ) {
        self.id = id
        self.cgFrame = cgFrame
        self.appKitFrame = appKitFrame
        self.appKitVisibleFrame = appKitVisibleFrame
        self.backingScaleFactor = backingScaleFactor
    }
}

public struct ConvertedWindowBounds: Codable, Equatable, Sendable {
    public let screenID: UInt32
    public let appKitBounds: RectValue

    public init(screenID: UInt32, appKitBounds: RectValue) {
        self.screenID = screenID
        self.appKitBounds = appKitBounds
    }
}

public enum CoordinateConversionError: Error, Equatable, Sendable {
    case noScreens
    case invalidWindowBounds
    case windowOutsideKnownScreens
}

public enum CoordinateConverter {
    public static func convert(
        cgWindowBounds: RectValue,
        screens: [DisplayGeometry]
    ) throws -> ConvertedWindowBounds {
        guard !screens.isEmpty else {
            throw CoordinateConversionError.noScreens
        }
        guard validRect(cgWindowBounds) else {
            throw CoordinateConversionError.invalidWindowBounds
        }
        guard screens.allSatisfy(validDisplay) else {
            throw CoordinateConversionError.invalidWindowBounds
        }

        let ranked = screens.map { screen in
            (screen: screen, overlap: screen.cgFrame.intersectionArea(with: cgWindowBounds))
        }
        guard let selected = ranked.max(by: { lhs, rhs in
            if lhs.overlap == rhs.overlap {
                return lhs.screen.id > rhs.screen.id
            }
            return lhs.overlap < rhs.overlap
        }), selected.overlap > 0 else {
            throw CoordinateConversionError.windowOutsideKnownScreens
        }

        let localX = cgWindowBounds.x - selected.screen.cgFrame.x
        let localYFromTop = cgWindowBounds.y - selected.screen.cgFrame.y
        let converted = RectValue(
            x: selected.screen.appKitFrame.x + localX,
            y: selected.screen.appKitFrame.maxY - localYFromTop - cgWindowBounds.height,
            width: cgWindowBounds.width,
            height: cgWindowBounds.height
        )
        return ConvertedWindowBounds(screenID: selected.screen.id, appKitBounds: converted)
    }

    private static func validDisplay(_ display: DisplayGeometry) -> Bool {
        validRect(display.cgFrame)
            && validRect(display.appKitFrame)
            && validRect(display.appKitVisibleFrame)
            && display.backingScaleFactor.isFinite
            && display.backingScaleFactor > 0
    }

    private static func validRect(_ rect: RectValue) -> Bool {
        rect.x.isFinite
            && rect.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
