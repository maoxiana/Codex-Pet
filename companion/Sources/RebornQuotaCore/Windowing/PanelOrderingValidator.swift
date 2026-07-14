import Foundation

public enum WindowNumberMetadataParser {
    public static func parse(_ value: NSNumber?) -> Int? {
        value?.intValue
    }
}

public struct WindowStableIdentity: Equatable, Sendable {
    public let windowNumber: Int?
    public let ownerPID: Int32
    public let layer: Int
    public let bounds: RectValue

    public init(
        windowNumber: Int?,
        ownerPID: Int32,
        layer: Int,
        bounds: RectValue
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }

    public init(window: WindowSnapshot) {
        self.init(
            windowNumber: window.windowNumber,
            ownerPID: window.ownerPID,
            layer: window.layer,
            bounds: window.bounds
        )
    }
}

public struct WindowOrderingRecord: Equatable, Sendable {
    public let windowNumber: Int?
    public let ownerPID: Int32
    public let layer: Int
    public let bounds: RectValue
    public let order: Int

    public init(
        windowNumber: Int?,
        ownerPID: Int32,
        layer: Int,
        bounds: RectValue,
        order: Int
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.order = order
    }
}

public enum PanelOrderingValidator {
    public static func isPanelAbove(
        panelWindowNumber: Int,
        candidate: WindowStableIdentity,
        windows: [WindowOrderingRecord]
    ) -> Bool {
        guard let panel = windows.first(where: {
            $0.windowNumber == Optional(panelWindowNumber)
        }) else {
            return false
        }
        let matches: [WindowOrderingRecord]
        if let windowNumber = candidate.windowNumber {
            matches = windows.filter {
                $0.windowNumber == Optional(windowNumber)
                    && $0.ownerPID == candidate.ownerPID
            }
        } else {
            matches = windows.filter {
                $0.ownerPID == candidate.ownerPID
                    && $0.layer == candidate.layer
                    && $0.bounds == candidate.bounds
            }
        }
        guard matches.count == 1, let target = matches.first else {
            return false
        }
        return panel.order < target.order
    }
}
