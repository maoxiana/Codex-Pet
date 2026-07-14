import XCTest
@testable import RebornQuotaCore

final class FollowLatencyTimingTests: XCTestCase {
    func testPollingFollowLatencyIncludesCaptureAndResolveDelay() {
        let origins = FollowLatencyTiming.origins(
            pollStartedAt: 10,
            axEventTimestamps: [],
            boundsMoved: true
        )

        let values = FollowLatencyTiming.milliseconds(origins: origins, committedAt: 10.080)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0], 80, accuracy: 0.001)
    }

    func testAXFollowLatencyStartsAtEventTimestamp() {
        let origins = FollowLatencyTiming.origins(
            pollStartedAt: 10,
            axEventTimestamps: [9.950],
            boundsMoved: true
        )

        let values = FollowLatencyTiming.milliseconds(origins: origins, committedAt: 10.080)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0], 130, accuracy: 0.001)
    }
}
