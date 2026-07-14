import XCTest
@testable import RebornQuotaCore

final class PanelOrderingValidatorTests: XCTestCase {
    func testPanelVerificationCarriesStableWindowNumberAcrossOrderChange() {
        let candidate = WindowStableIdentity(
            windowNumber: 42,
            ownerPID: 7_981,
            layer: 3,
            bounds: rect(100, 150, 356, 320)
        )
        let afterOrdering = [
            WindowOrderingRecord(
                windowNumber: 99,
                ownerPID: 123,
                layer: 4,
                bounds: rect(100, 150, 14, 14),
                order: 10
            ),
            WindowOrderingRecord(
                windowNumber: 42,
                ownerPID: 7_981,
                layer: 3,
                bounds: rect(100, 150, 356, 320),
                order: 162
            ),
        ]

        XCTAssertTrue(PanelOrderingValidator.isPanelAbove(
            panelWindowNumber: 99,
            candidate: candidate,
            windows: afterOrdering
        ))
    }

    func testPanelVerificationFallbackUsesPIDLayerAndFullBoundsNotOldOrder() {
        let candidate = WindowStableIdentity(
            windowNumber: nil,
            ownerPID: 7_981,
            layer: 3,
            bounds: rect(100, 150, 356, 320)
        )
        let afterOrdering = [
            WindowOrderingRecord(
                windowNumber: 99,
                ownerPID: 123,
                layer: 4,
                bounds: rect(100, 150, 14, 14),
                order: 10
            ),
            WindowOrderingRecord(
                windowNumber: nil,
                ownerPID: 7_981,
                layer: 3,
                bounds: rect(100, 150, 356, 320),
                order: 160
            ),
        ]

        XCTAssertTrue(PanelOrderingValidator.isPanelAbove(
            panelWindowNumber: 99,
            candidate: candidate,
            windows: afterOrdering
        ))
    }

    func testStableIdentityPreservesMissingWindowNumber() {
        let window = WindowSnapshot(
            windowNumber: nil,
            ownerPID: 7_981,
            resolvedBundleID: "com.openai.codex",
            ownerName: "ChatGPT",
            layer: 3,
            bounds: rect(100, 150, 356, 320),
            alpha: 1,
            isOnScreen: true,
            sharingState: 1,
            title: nil,
            order: 100
        )

        XCTAssertNil(WindowStableIdentity(window: window).windowNumber)
    }

    func testWindowNumberMetadataParserPreservesMissingValueAsNil() {
        XCTAssertNil(WindowNumberMetadataParser.parse(nil))
        XCTAssertEqual(WindowNumberMetadataParser.parse(NSNumber(value: 42)), 42)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
