import RebornQuotaCore
import SwiftUI

struct QuotaBubbleView: View {
    // The panel is a fixed, noninteractive status surface. Mouse events pass
    // through at the window level, so it never changes size or steals Codex focus.
    let presentation: QuotaPresentation
    let side: BubbleSide

    private let rebornOrange = Color(red: 1.0, green: 0.42, blue: 0.06)
    private let warmBlack = Color(red: 0.075, green: 0.067, blue: 0.063)

    var body: some View {
        ZStack {
            BubbleSilhouette(side: side)
                .fill(warmBlack.opacity(0.96))
                .overlay {
                    BubbleSilhouette(side: side)
                        .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                }

            fixedContent
                .padding(.horizontal, 12)
                .padding(side == .below ? .top : .bottom, 7)
        }
        // Fixed companion-window bounds cap visual Dynamic Type at Large. VoiceOver
        // exposes the full untruncated status/value for larger-accessibility needs.
        .dynamicTypeSize(.xSmall ... .large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText.label)
        .accessibilityValue(accessibilityText.value)
    }

    private var fixedContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(presentation.percent == nil ? presentation.title : "本周剩余")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                Spacer(minLength: 4)
                if let percent = presentation.percent {
                    Text("\(percent)%")
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(rebornOrange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel("本周剩余额度")
                        .accessibilityValue("百分之\(percent)")
                } else if presentation.detail != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(rebornOrange)
                        .accessibilityLabel("正在更新每周额度")
                }
            }

            Text(secondaryText)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.68))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(secondaryAccessibilityLabel)
        }
    }

    private var secondaryText: String {
        presentation.resetText ?? presentation.detail ?? fallbackStatusText
    }

    private var fallbackStatusText: String {
        switch presentation.title {
        case "正在读取额度": "正在连接 Codex"
        case "暂无每周额度": "当前账户未返回每周窗口"
        case "额度暂不可用": "请稍后重试"
        case "额度信息已过期": "正在等待最新数据"
        default: "重置时间暂不可用"
        }
    }

    private var secondaryAccessibilityLabel: String {
        if let reset = presentation.resetText { return reset }
        return secondaryText
    }

    private var accessibilityText: BubbleAccessibilityText {
        BubbleAccessibilityFormatter.format(presentation: presentation)
    }
}

private struct BubbleSilhouette: Shape {
    let side: BubbleSide
    private let arrowWidth: CGFloat = 14
    private let arrowHeight: CGFloat = 7
    private let cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        guard let geometry = BubbleSilhouetteLayout.geometry(
            side: side,
            bounds: RectValue(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height
            ),
            arrowHeight: arrowHeight
        ) else { return Path() }
        let body = CGRect(
            x: geometry.body.x,
            y: geometry.body.y,
            width: geometry.body.width,
            height: geometry.body.height
        )
        var path = Path(roundedRect: body, cornerRadius: cornerRadius)
        let centerX = rect.midX
        switch side {
        case .above:
            path.move(to: CGPoint(
                x: centerX - arrowWidth / 2,
                y: geometry.arrowBaseY - 1
            ))
            path.addLine(to: CGPoint(x: centerX, y: geometry.arrowTipY))
            path.addLine(to: CGPoint(
                x: centerX + arrowWidth / 2,
                y: geometry.arrowBaseY - 1
            ))
        case .below:
            path.move(to: CGPoint(
                x: centerX - arrowWidth / 2,
                y: geometry.arrowBaseY + 1
            ))
            path.addLine(to: CGPoint(x: centerX, y: geometry.arrowTipY))
            path.addLine(to: CGPoint(
                x: centerX + arrowWidth / 2,
                y: geometry.arrowBaseY + 1
            ))
        }
        path.closeSubpath()
        return path
    }
}
