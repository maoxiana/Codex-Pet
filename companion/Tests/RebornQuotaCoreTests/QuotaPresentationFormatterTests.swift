import Foundation
import XCTest
@testable import RebornQuotaCore

final class QuotaPresentationFormatterTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private let locale = Locale(identifier: "zh_CN")

    func testLoadingUsesChineseCopy() {
        let presentation = formatter().format(.loading)

        XCTAssertEqual(presentation.title, "正在读取额度")
        XCTAssertNil(presentation.detail)
        XCTAssertNil(presentation.percent)
        XCTAssertNil(presentation.progress)
        XCTAssertNil(presentation.resetText)
    }

    func testFreshAvailableFormatsCompactValuesAndExpandedLocalReset() {
        let updatedAt = localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)
        let resetsAt = localDate(year: 2026, month: 7, day: 14, hour: 8, minute: 30)
        let quota = WeeklyQuota(
            remainingPercent: 73,
            resetsAt: resetsAt,
            fingerprint: "fresh"
        )

        let presentation = formatter().format(.available(quota, lastUpdatedAt: updatedAt))

        XCTAssertEqual(presentation.title, "本周剩余")
        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.percent, 73)
        XCTAssertEqual(presentation.progress ?? -1, 0.73, accuracy: 0.000_001)
        XCTAssertEqual(presentation.resetText, "重置时间：7月14日 08:30")
    }

    func testRefreshingWithLastKnownKeepsCompactValues() {
        let quota = WeeklyQuota(
            remainingPercent: 41,
            resetsAt: localDate(year: 2026, month: 7, day: 14, hour: 8, minute: 30),
            fingerprint: "known"
        )

        let presentation = formatter().format(
            .refreshing(
                lastKnown: quota,
                since: localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)
            )
        )

        XCTAssertEqual(presentation.title, "本周剩余")
        XCTAssertEqual(presentation.detail, "正在更新")
        XCTAssertEqual(presentation.percent, 41)
        XCTAssertEqual(presentation.progress ?? -1, 0.41, accuracy: 0.000_001)
        XCTAssertEqual(presentation.resetText, "重置时间正在更新")
    }

    func testRefreshingWithoutHistoryUsesLoadingCopy() {
        let presentation = formatter().format(
            .refreshing(
                lastKnown: nil,
                since: localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)
            )
        )

        XCTAssertEqual(presentation.title, "正在读取额度")
        XCTAssertEqual(presentation.detail, "正在更新")
        XCTAssertNil(presentation.percent)
        XCTAssertNil(presentation.progress)
        XCTAssertNil(presentation.resetText)
    }

    func testNoWeeklyWindowUsesChineseCopy() {
        let presentation = formatter().format(.noWeeklyWindow)

        XCTAssertEqual(presentation.title, "暂无每周额度")
        XCTAssertNil(presentation.detail)
    }

    func testUnavailableAndStaleUseDistinctCopy() {
        let unavailable = formatter().format(.unavailable(.transportError))
        let stale = formatter().format(.unavailable(.staleSnapshot))

        XCTAssertEqual(unavailable.title, "额度暂不可用")
        XCTAssertEqual(unavailable.detail, "请稍后重试")
        XCTAssertEqual(stale.title, "额度信息已过期")
        XCTAssertEqual(stale.detail, "正在等待最新数据")
    }

    func testMissingResetUsesUnavailableResetCopy() {
        let quota = WeeklyQuota(
            remainingPercent: 88,
            resetsAt: nil,
            fingerprint: "missing-reset"
        )
        let updatedAt = localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)

        let presentation = formatter().format(.available(quota, lastUpdatedAt: updatedAt))

        XCTAssertEqual(presentation.resetText, "重置时间暂不可用")
    }

    func testExpiredResetNeverRendersStaleTime() {
        let reset = localDate(year: 2026, month: 7, day: 12, hour: 8, minute: 30)
        let updatedAt = localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)
        let quota = WeeklyQuota(
            remainingPercent: 12,
            resetsAt: reset,
            fingerprint: "expired"
        )

        let presentation = formatter().format(.available(quota, lastUpdatedAt: updatedAt))

        XCTAssertEqual(presentation.resetText, "重置时间正在更新")
        XCTAssertFalse(presentation.resetText?.contains("7月12日") ?? true)
    }

    func testTransitionDurationIsNormalOrReducedMotion() {
        let normal = formatter().format(.loading)
        let reduced = formatter().format(.loading, reducedMotion: true)

        XCTAssertEqual(normal.transitionDuration, 0.140, accuracy: 0.000_001)
        XCTAssertEqual(reduced.transitionDuration, 0, accuracy: 0.000_001)
    }

    func testDirectInvalidPercentValuesAreClamped() {
        let updatedAt = localDate(year: 2026, month: 7, day: 13, hour: 9, minute: 0)
        let reset = localDate(year: 2026, month: 7, day: 14, hour: 9, minute: 0)
        let belowZero = WeeklyQuota(
            remainingPercent: -40,
            resetsAt: reset,
            fingerprint: "below-zero"
        )
        let aboveOneHundred = WeeklyQuota(
            remainingPercent: 140,
            resetsAt: reset,
            fingerprint: "above-one-hundred"
        )

        let low = formatter().format(.available(belowZero, lastUpdatedAt: updatedAt))
        let high = formatter().format(.available(aboveOneHundred, lastUpdatedAt: updatedAt))

        XCTAssertEqual(low.percent, 0)
        XCTAssertEqual(low.progress, 0)
        XCTAssertEqual(high.percent, 100)
        XCTAssertEqual(high.progress, 1)
    }

    func testInjectedTimeZoneControlsResetDateAcrossDayBoundary() {
        let reset = ISO8601DateFormatter().date(from: "2026-07-13T16:30:00Z")!
        let updatedAt = reset.addingTimeInterval(-3_600)
        let quota = WeeklyQuota(
            remainingPercent: 50,
            resetsAt: reset,
            fingerprint: "date-boundary"
        )

        let shanghai = formatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
            .format(.available(quota, lastUpdatedAt: updatedAt))
        let losAngeles = formatter(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
            .format(.available(quota, lastUpdatedAt: updatedAt))

        XCTAssertEqual(shanghai.resetText, "重置时间：7月14日 00:30")
        XCTAssertEqual(losAngeles.resetText, "重置时间：7月13日 09:30")
    }

    private func formatter(timeZone: TimeZone? = nil) -> QuotaPresentationFormatter {
        let timeZone = timeZone ?? self.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return QuotaPresentationFormatter(
            calendar: calendar,
            timeZone: timeZone,
            locale: locale
        )
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
