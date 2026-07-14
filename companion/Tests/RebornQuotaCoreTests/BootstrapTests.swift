import XCTest
@testable import RebornQuotaCore

final class BootstrapTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(RebornQuotaCoreVersion.current, "0.1.0")
    }
}
