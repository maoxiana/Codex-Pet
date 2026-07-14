import Foundation

public struct BubbleAccessibilityText: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum BubbleAccessibilityFormatter {
    public static func format(
        presentation: QuotaPresentation
    ) -> BubbleAccessibilityText {
        var values: [String] = []
        if let percent = presentation.percent {
            values.append("剩余百分之\(percent)")
        } else {
            values.append(presentation.title)
        }
        if let detail = presentation.detail { values.append(detail) }
        if let reset = presentation.resetText { values.append(reset) }
        return BubbleAccessibilityText(
            label: "每周额度",
            value: values.joined(separator: "，")
        )
    }
}
