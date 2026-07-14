import XCTest
@testable import RebornQuotaCore

final class CoordinateConverterTests: XCTestCase {
    func testRejectsNonfiniteWindowOriginAndSize() {
        let screens = [display(id: 1, cg: rect(0, 0, 1_440, 900), appKit: rect(0, 0, 1_440, 900))]

        XCTAssertThrowsError(try CoordinateConverter.convert(
            cgWindowBounds: rect(.nan, 10, 100, 100),
            screens: screens
        ))
        XCTAssertThrowsError(try CoordinateConverter.convert(
            cgWindowBounds: rect(10, 10, .infinity, 100),
            screens: screens
        ))
    }

    func testRejectsNonfiniteDisplayGeometry() {
        let invalid = display(
            id: 1,
            cg: rect(0, 0, .infinity, 900),
            appKit: rect(0, 0, 1_440, 900)
        )

        XCTAssertThrowsError(try CoordinateConverter.convert(
            cgWindowBounds: rect(10, 10, 100, 100),
            screens: [invalid]
        ))
    }

    func testConvertsPrimaryScreenFromTopLeftToBottomLeftCoordinates() throws {
        let screens = [display(id: 1, cg: rect(0, 0, 1_440, 900), appKit: rect(0, 0, 1_440, 900))]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(100, 150, 320, 200),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 1)
        XCTAssertEqual(result.appKitBounds, rect(100, 550, 320, 200))
    }

    func testConvertsWindowOnNegativeOriginLeftScreen() throws {
        let screens = [
            display(id: 1, cg: rect(0, 0, 1_440, 900), appKit: rect(0, 0, 1_440, 900)),
            display(id: 2, cg: rect(-1_920, -180, 1_920, 1_080), appKit: rect(-1_920, 0, 1_920, 1_080)),
        ]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(-1_800, -80, 300, 240),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 2)
        XCTAssertEqual(result.appKitBounds, rect(-1_800, 740, 300, 240))
    }

    func testConvertsWindowOnScreenAbovePrimary() throws {
        let screens = [
            display(id: 1, cg: rect(0, 0, 1_440, 900), appKit: rect(0, 0, 1_440, 900)),
            display(id: 3, cg: rect(160, -900, 1_280, 800), appKit: rect(160, 1_000, 1_280, 800)),
        ]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(200, -850, 400, 300),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 3)
        XCTAssertEqual(result.appKitBounds, rect(200, 1_450, 400, 300))
    }

    func testConvertsWindowOnScreenBelowPrimary() throws {
        let screens = [
            display(id: 1, cg: rect(0, 0, 1_440, 900), appKit: rect(0, 0, 1_440, 900)),
            display(id: 4, cg: rect(80, 900, 1_280, 800), appKit: rect(80, -800, 1_280, 800)),
        ]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(180, 1_000, 240, 160),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 4)
        XCTAssertEqual(result.appKitBounds, rect(180, -260, 240, 160))
    }

    func testScreenSelectionUsesFullFramesRatherThanMixedVisibleFrames() throws {
        let screens = [
            display(
                id: 1,
                cg: rect(0, 0, 1_440, 900),
                appKit: rect(0, 0, 1_440, 900),
                visible: rect(0, 25, 1_440, 850)
            ),
            display(
                id: 5,
                cg: rect(1_440, 0, 1_920, 1_080),
                appKit: rect(1_440, -180, 1_920, 1_080),
                visible: rect(1_440, -180, 1_920, 1_055)
            ),
        ]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(1_500, 10, 400, 120),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 5)
        XCTAssertEqual(result.appKitBounds, rect(1_500, 770, 400, 120))
    }

    func testRetinaScaleIsNotAppliedToLogicalWindowBounds() throws {
        let screens = [
            display(
                id: 6,
                cg: rect(0, 0, 1_512, 982),
                appKit: rect(0, 0, 1_512, 982),
                scale: 2
            ),
        ]

        let result = try CoordinateConverter.convert(
            cgWindowBounds: rect(256, 100, 500, 300),
            screens: screens
        )

        XCTAssertEqual(result.screenID, 6)
        XCTAssertEqual(result.appKitBounds, rect(256, 582, 500, 300))
    }

    private func display(
        id: UInt32,
        cg: RectValue,
        appKit: RectValue,
        visible: RectValue? = nil,
        scale: Double = 1
    ) -> DisplayGeometry {
        DisplayGeometry(
            id: id,
            cgFrame: cg,
            appKitFrame: appKit,
            appKitVisibleFrame: visible ?? appKit,
            backingScaleFactor: scale
        )
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }
}
