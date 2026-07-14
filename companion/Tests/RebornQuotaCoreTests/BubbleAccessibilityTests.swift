import XCTest
@testable import RebornQuotaCore

final class BubbleAccessibilityTests: XCTestCase {
    func testAvailableBubbleExposesPercentAndResetWithoutInteractionState() {
        let presentation = QuotaPresentation(
            title: "本周剩余",
            detail: nil,
            percent: 72,
            progress: 0.72,
            resetText: "重置时间：7月20日 08:00",
            transitionDuration: 0.140
        )
        let accessibility = BubbleAccessibilityFormatter.format(presentation: presentation)

        XCTAssertEqual(accessibility.label, "每周额度")
        XCTAssertTrue(accessibility.value.contains("剩余百分之72"))
        XCTAssertTrue(accessibility.value.contains("重置时间：7月20日 08:00"))
        XCTAssertFalse(accessibility.value.contains("展开"))
        XCTAssertFalse(accessibility.value.contains("固定"))
    }

    func testUnavailableBubbleAnnouncesStatusWithoutInventingPercent() {
        let presentation = QuotaPresentation(
            title: "额度暂不可用",
            detail: "请稍后重试",
            percent: nil,
            progress: nil,
            resetText: nil,
            transitionDuration: 0
        )
        let accessibility = BubbleAccessibilityFormatter.format(presentation: presentation)

        XCTAssertEqual(accessibility.label, "每周额度")
        XCTAssertEqual(accessibility.value, "额度暂不可用，请稍后重试")
    }
}
