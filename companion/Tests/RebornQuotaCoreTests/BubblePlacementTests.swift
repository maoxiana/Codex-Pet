import XCTest
@testable import RebornQuotaCore

final class BubblePlacementTests: XCTestCase {
    func testAboveBubbleReservesBottomArrowWithTipAtLocalMaxY() throws {
        let geometry = try XCTUnwrap(BubbleSilhouetteLayout.geometry(
            side: .above,
            bounds: RectValue(x: 0, y: 0, width: 164, height: 32),
            arrowHeight: 7
        ))

        XCTAssertEqual(geometry.body, RectValue(x: 0, y: 0, width: 164, height: 25))
        XCTAssertEqual(geometry.arrowBaseY, 25)
        XCTAssertEqual(geometry.arrowTipY, 32)
    }

    func testBelowBubbleReservesTopArrowWithTipAtLocalMinY() throws {
        let geometry = try XCTUnwrap(BubbleSilhouetteLayout.geometry(
            side: .below,
            bounds: RectValue(x: 0, y: 0, width: 200, height: 82),
            arrowHeight: 7
        ))

        XCTAssertEqual(geometry.body, RectValue(x: 0, y: 7, width: 200, height: 75))
        XCTAssertEqual(geometry.arrowBaseY, 7)
        XCTAssertEqual(geometry.arrowTipY, 0)
    }

    func testSilhouetteHitRegionExcludesTransparentCornersAndIncludesBodyAndArrow() {
        let bounds = RectValue(x: 0, y: 0, width: 164, height: 32)

        XCTAssertFalse(BubbleSilhouetteHitRegion.contains(
            PointValue(x: 0, y: 0),
            side: .above,
            bounds: bounds,
            arrowWidth: 14,
            arrowHeight: 7,
            cornerRadius: 10
        ))
        XCTAssertTrue(BubbleSilhouetteHitRegion.contains(
            PointValue(x: 20, y: 10),
            side: .above,
            bounds: bounds,
            arrowWidth: 14,
            arrowHeight: 7,
            cornerRadius: 10
        ))
        XCTAssertTrue(BubbleSilhouetteHitRegion.contains(
            PointValue(x: 82, y: 30),
            side: .above,
            bounds: bounds,
            arrowWidth: 14,
            arrowHeight: 7,
            cornerRadius: 10
        ))
        XCTAssertFalse(BubbleSilhouetteHitRegion.contains(
            PointValue(x: 60, y: 30),
            side: .above,
            bounds: bounds,
            arrowWidth: 14,
            arrowHeight: 7,
            cornerRadius: 10
        ))
    }

    func testWindowHitPolicyPassesTransparentPanelCornersThroughButKeepsBubbleInteractive() {
        let frame = RectValue(x: 100, y: 200, width: 164, height: 32)

        XCTAssertEqual(
            BubbleWindowHitPolicy.classify(
                screenPoint: PointValue(x: 120, y: 220),
                panelFrame: frame,
                side: .above
            ),
            .insideSilhouette
        )
        XCTAssertEqual(
            BubbleWindowHitPolicy.classify(
                screenPoint: PointValue(x: 182, y: 202),
                panelFrame: frame,
                side: .above
            ),
            .insideSilhouette,
            "Above-pet arrow occupies the AppKit bottom edge"
        )
        XCTAssertEqual(
            BubbleWindowHitPolicy.classify(
                screenPoint: PointValue(x: 100, y: 231),
                panelFrame: frame,
                side: .above
            ),
            .transparentPanelArea
        )
        XCTAssertTrue(BubbleWindowHitPolicy.shouldIgnoreMouseEvents(
            screenPoint: PointValue(x: 100, y: 231),
            panelFrame: frame,
            side: .above
        ))
        XCTAssertEqual(
            BubbleWindowHitPolicy.classify(
                screenPoint: PointValue(x: 80, y: 220),
                panelFrame: frame,
                side: .above
            ),
            .outsidePanel
        )
        XCTAssertFalse(BubbleWindowHitPolicy.shouldIgnoreMouseEvents(
            screenPoint: PointValue(x: 80, y: 220),
            panelFrame: frame,
            side: .above
        ), "Outside resets pass-through so future entry can be detected")
    }

    func testPanelFramePreservesPetFacingEdgeAndLevelIsSafelyClamped() throws {
        let placement = BubblePlacement(origin: PointValue(x: 100, y: 200), side: .above)
        XCTAssertEqual(
            QuotaPanelGeometry.frame(
                expandedPlacement: placement,
                expandedSize: SizeValue(width: 200, height: 82),
                currentSize: SizeValue(width: 164, height: 32)
            ),
            RectValue(x: 118, y: 200, width: 164, height: 32)
        )

        let below = BubblePlacement(origin: PointValue(x: 100, y: 200), side: .below)
        XCTAssertEqual(
            QuotaPanelGeometry.frame(
                expandedPlacement: below,
                expandedSize: SizeValue(width: 200, height: 82),
                currentSize: SizeValue(width: 164, height: 32)
            ),
            RectValue(x: 118, y: 250, width: 164, height: 32)
        )
        XCTAssertEqual(QuotaPanelGeometry.safeLevel(petLayer: 3, floating: 3, screenSaver: 1_000), 4)
        XCTAssertEqual(QuotaPanelGeometry.safeLevel(petLayer: -9, floating: 3, screenSaver: 1_000), 3)
        XCTAssertEqual(QuotaPanelGeometry.safeLevel(petLayer: .max, floating: 3, screenSaver: 1_000), 999)
    }

    func testPlacementSessionLocksSideUntilHideOrScreenContextChanges() throws {
        var session = BubblePlacementSession()
        let first = try XCTUnwrap(session.update(
            petFrame: rect(120, 330, 80, 50),
            screenID: 1,
            screenVisibleFrame: rect(0, 0, 400, 400),
            expandedSize: size(180, 100),
            gap: 12
        ))
        XCTAssertEqual(first.placement.side, .below)
        XCTAssertFalse(first.contextChanged)

        let moved = try XCTUnwrap(session.update(
            petFrame: rect(120, 180, 80, 40),
            screenID: 1,
            screenVisibleFrame: rect(0, 0, 400, 400),
            expandedSize: size(180, 100),
            gap: 12
        ))
        XCTAssertEqual(moved.placement.side, .below, "Same screen preserves the locked side")
        XCTAssertFalse(moved.contextChanged)

        let crossed = try XCTUnwrap(session.update(
            petFrame: rect(520, 180, 80, 40),
            screenID: 2,
            screenVisibleFrame: rect(400, 0, 400, 400),
            expandedSize: size(180, 100),
            gap: 12
        ))
        XCTAssertEqual(crossed.placement.side, .above)
        XCTAssertTrue(crossed.contextChanged)

        session.reset()
        XCTAssertNil(session.lockedSide)
        XCTAssertNil(session.screenID)
    }

    func testPrefersAboveAndCentersExpandedEnvelope() {
        XCTAssertEqual(
            choose(
                pet: rect(100, 100, 80, 80),
                screen: rect(0, 0, 400, 400),
                size: size(160, 70),
                gap: 12
            ),
            BubblePlacement(origin: point(60, 192), side: .above)
        )
    }

    func testCentersThenClampsEntirelyInsideVisibleFrame() {
        XCTAssertEqual(
            choose(
                pet: rect(-245, 1_050, 40, 40),
                screen: rect(-220, 982, 2_560, 1_440),
                size: size(300, 100),
                gap: 8
            ),
            BubblePlacement(origin: point(-220, 1_098), side: .above)
        )
        XCTAssertEqual(
            choose(
                pet: rect(2_300, 1_050, 80, 40),
                screen: rect(-220, 982, 2_560, 1_440),
                size: size(300, 100),
                gap: 8
            ),
            BubblePlacement(origin: point(2_040, 1_098), side: .above)
        )
    }

    func testFallsBelowAndFlipsSideWhenExpandedEnvelopeCannotFitAbove() {
        XCTAssertEqual(
            choose(
                pet: rect(120, 330, 80, 50),
                screen: rect(0, 0, 400, 400),
                size: size(180, 100),
                gap: 12
            ),
            BubblePlacement(origin: point(70, 218), side: .below)
        )
    }

    func testHidesWhenNeitherSideCanFitExpandedEnvelope() {
        XCTAssertNil(
            choose(
                pet: rect(100, 80, 80, 40),
                screen: rect(0, 0, 300, 200),
                size: size(160, 90),
                gap: 16
            )
        )
    }

    func testSupportsNegativeAndMixedDisplayCoordinatesWithoutScaleConversion() {
        XCTAssertEqual(
            choose(
                pet: rect(-900, -850, 120, 100),
                screen: rect(-1_200, -900, 800, 600),
                size: size(260, 120),
                gap: 10
            ),
            BubblePlacement(origin: point(-970, -740), side: .above)
        )
    }

    func testLockedSideIsPreservedAndNeverFlipsDuringSizeTransition() {
        let pet = rect(120, 310, 80, 40)
        let screen = rect(0, 0, 400, 400)
        let expanded = choose(
            pet: pet,
            screen: screen,
            size: size(180, 80),
            gap: 10
        )
        XCTAssertEqual(expanded?.side, .below)
        XCTAssertEqual(
            choose(
                pet: pet,
                screen: screen,
                size: size(120, 30),
                gap: 10
            )?.side,
            .above,
            "A compact-only calculation would flip sides"
        )
        XCTAssertEqual(
            choose(
                pet: pet,
                screen: screen,
                size: size(120, 30),
                gap: 10,
                lockedSide: expanded?.side
            )?.side,
            .below,
            "The expanded-envelope side stays locked while compact"
        )

        XCTAssertEqual(
            choose(
                pet: rect(120, 180, 80, 40),
                screen: rect(0, 0, 400, 400),
                size: size(180, 80),
                gap: 10,
                lockedSide: .below
            ),
            BubblePlacement(origin: point(70, 90), side: .below)
        )
        XCTAssertNil(
            choose(
                pet: rect(120, 330, 80, 50),
                screen: rect(0, 0, 400, 400),
                size: size(180, 100),
                gap: 12,
                lockedSide: .above
            )
        )
    }

    func testRejectsNonFiniteOrNonPositiveGeometryAndNegativeGap() {
        let validPet = rect(100, 100, 80, 80)
        let validScreen = rect(0, 0, 400, 400)
        let validSize = size(160, 70)

        XCTAssertNil(choose(pet: rect(.nan, 100, 80, 80), screen: validScreen, size: validSize))
        XCTAssertNil(choose(pet: validPet, screen: rect(0, 0, .infinity, 400), size: validSize))
        XCTAssertNil(choose(pet: validPet, screen: validScreen, size: size(0, 70)))
        XCTAssertNil(choose(pet: validPet, screen: validScreen, size: validSize, gap: -1))
        XCTAssertNil(choose(pet: validPet, screen: validScreen, size: validSize, gap: .infinity))
    }

    func testRejectsFiniteInputsWhoseDerivedExtentsOverflow() {
        let huge = Double.greatestFiniteMagnitude

        XCTAssertNil(
            choose(
                pet: rect(huge, 100, huge, 80),
                screen: rect(0, 0, huge, 400),
                size: size(160, 70),
                gap: 12
            ),
            "A finite pet origin and size must not produce an infinite extent or center"
        )
        XCTAssertNil(
            choose(
                pet: rect(huge, huge, 100, 80),
                screen: rect(huge, huge, huge, huge),
                size: size(50, 70),
                gap: 10
            ),
            "Derived screen/pet extents and origins must remain finite"
        )
    }

    private func choose(
        pet: RectValue,
        screen: RectValue,
        size: SizeValue,
        gap: Double = 0,
        lockedSide: BubbleSide? = nil
    ) -> BubblePlacement? {
        BubblePlacementEngine.choose(
            petFrame: pet,
            screenVisibleFrame: screen,
            expandedSize: size,
            gap: gap,
            lockedSide: lockedSide
        )
    }

    private func point(_ x: Double, _ y: Double) -> PointValue {
        PointValue(x: x, y: y)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> RectValue {
        RectValue(x: x, y: y, width: width, height: height)
    }

    private func size(_ width: Double, _ height: Double) -> SizeValue {
        SizeValue(width: width, height: height)
    }
}
