import XCTest
@testable import RebornQuotaCore

final class EvaluationPolicyTests: XCTestCase {
    func testEvaluateOptionsAreStrictByDefault() throws {
        let options = try EvaluationOptions.parse(arguments: [
            "--snapshots-dir", "qa/window-probe",
            "--metrics-dir", "qa/window-probe/metrics",
            "--output", "qa/window-probe/gate-result.json",
        ])

        XCTAssertFalse(options.deferPerformance)
        XCTAssertNil(options.deferralNote)
    }

    func testEvaluateOptionsAcceptExplicitPerformanceDeferral() throws {
        let options = try EvaluationOptions.parse(arguments: [
            "--snapshots-dir", "qa/window-probe",
            "--metrics-dir", "qa/window-probe/metrics",
            "--defer-performance",
            "--deferral-note", "User requested implementation continue without more scenarios",
            "--output", "qa/window-probe/gate-result.json",
        ])

        XCTAssertTrue(options.deferPerformance)
        XCTAssertEqual(
            options.deferralNote,
            "User requested implementation continue without more scenarios"
        )
    }

    func testDeferralRequiresNonemptyNote() {
        XCTAssertThrowsError(try EvaluationOptions.parse(arguments: [
            "--snapshots-dir", "qa/window-probe",
            "--metrics-dir", "qa/window-probe/metrics",
            "--defer-performance",
            "--deferral-note", "   ",
            "--output", "qa/window-probe/gate-result.json",
        ])) { error in
            XCTAssertEqual(error as? EvaluationOptionsError, .deferralNoteRequired)
        }
    }

    func testDeferralAllowsDevelopmentOnlyWhenIdentificationPassed() {
        let approved = GateDecisionPolicy.decide(
            identificationPassed: true,
            performanceVerified: false,
            deferPerformance: true,
            deferralNote: "User deferred performance QA"
        )
        let blocked = GateDecisionPolicy.decide(
            identificationPassed: false,
            performanceVerified: false,
            deferPerformance: true,
            deferralNote: "User deferred performance QA"
        )

        XCTAssertTrue(approved.passed)
        XCTAssertTrue(approved.performanceDeferred)
        XCTAssertFalse(approved.performanceVerified)
        XCTAssertFalse(blocked.passed)
    }
}

