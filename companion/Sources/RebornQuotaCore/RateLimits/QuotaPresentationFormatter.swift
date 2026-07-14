import Foundation

public struct QuotaPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let percent: Int?
    public let progress: Double?
    public let resetText: String?
    public let transitionDuration: TimeInterval

    public init(
        title: String,
        detail: String?,
        percent: Int?,
        progress: Double?,
        resetText: String?,
        transitionDuration: TimeInterval
    ) {
        self.title = title
        self.detail = detail
        self.percent = percent
        self.progress = progress
        self.resetText = resetText
        self.transitionDuration = transitionDuration
    }
}

public struct QuotaPresentationFormatter: Sendable {
    public static let transitionDuration: TimeInterval = 0.140

    private let calendar: Calendar
    private let timeZone: TimeZone
    private let locale: Locale

    public init(calendar: Calendar, timeZone: TimeZone, locale: Locale) {
        var configuredCalendar = calendar
        configuredCalendar.timeZone = timeZone
        configuredCalendar.locale = locale
        self.calendar = configuredCalendar
        self.timeZone = timeZone
        self.locale = locale
    }

    public func format(
        _ state: QuotaDisplayState,
        reducedMotion: Bool = false
    ) -> QuotaPresentation {
        let transition = reducedMotion ? 0 : Self.transitionDuration

        switch state {
        case .loading:
            return QuotaPresentation(
                title: "正在读取额度",
                detail: nil,
                percent: nil,
                progress: nil,
                resetText: nil,
                transitionDuration: transition
            )

        case .available(let quota, let lastUpdatedAt):
            return quotaPresentation(
                quota,
                detail: nil,
                resetText: resetText(for: quota, relativeTo: lastUpdatedAt),
                transitionDuration: transition
            )

        case .refreshing(let lastKnown?, _):
            return quotaPresentation(
                lastKnown,
                detail: "正在更新",
                resetText: "重置时间正在更新",
                transitionDuration: transition
            )

        case .refreshing(lastKnown: nil, _):
            return QuotaPresentation(
                title: "正在读取额度",
                detail: "正在更新",
                percent: nil,
                progress: nil,
                resetText: nil,
                transitionDuration: transition
            )

        case .noWeeklyWindow:
            return QuotaPresentation(
                title: "暂无每周额度",
                detail: nil,
                percent: nil,
                progress: nil,
                resetText: nil,
                transitionDuration: transition
            )

        case .unavailable(.transportError):
            return QuotaPresentation(
                title: "额度暂不可用",
                detail: "请稍后重试",
                percent: nil,
                progress: nil,
                resetText: nil,
                transitionDuration: transition
            )

        case .unavailable(.staleSnapshot):
            return QuotaPresentation(
                title: "额度信息已过期",
                detail: "正在等待最新数据",
                percent: nil,
                progress: nil,
                resetText: nil,
                transitionDuration: transition
            )
        }
    }

    private func quotaPresentation(
        _ quota: WeeklyQuota,
        detail: String?,
        resetText: String,
        transitionDuration: TimeInterval
    ) -> QuotaPresentation {
        let percent = min(max(quota.remainingPercent, 0), 100)
        return QuotaPresentation(
            title: "本周剩余",
            detail: detail,
            percent: percent,
            progress: Double(percent) / 100,
            resetText: resetText,
            transitionDuration: transitionDuration
        )
    }

    private func resetText(for quota: WeeklyQuota, relativeTo lastUpdatedAt: Date) -> String {
        guard let resetsAt = quota.resetsAt else {
            return "重置时间暂不可用"
        }
        guard resetsAt > lastUpdatedAt else {
            return "重置时间正在更新"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = "M月d日 HH:mm"
        return "重置时间：\(formatter.string(from: resetsAt))"
    }
}
