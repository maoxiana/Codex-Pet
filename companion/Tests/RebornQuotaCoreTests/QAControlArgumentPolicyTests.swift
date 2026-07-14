import XCTest
@testable import RebornQuotaCore

final class QAControlArgumentPolicyTests: XCTestCase {
    func testRestartDelayAcceptsFiniteBoundedSecondsOnly() {
        XCTAssertEqual(QAControlArgumentPolicy.restartDelaySeconds("0"), 0)
        XCTAssertEqual(QAControlArgumentPolicy.restartDelaySeconds("86400"), 86_400)
        XCTAssertNil(QAControlArgumentPolicy.restartDelaySeconds("nan"))
        XCTAssertNil(QAControlArgumentPolicy.restartDelaySeconds("inf"))
        XCTAssertNil(QAControlArgumentPolicy.restartDelaySeconds("-1"))
        XCTAssertNil(QAControlArgumentPolicy.restartDelaySeconds("86400.1"))
        XCTAssertNil(QAControlArgumentPolicy.restartDelaySeconds("not-a-number"))
    }
}
