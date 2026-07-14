import Foundation
import XCTest
@testable import RebornQuotaCore

final class GateProcessExitTests: XCTestCase {
    func testGateFailureUsesDistinctNonzeroExitCode() {
        XCTAssertEqual(GateProcessExit.code(passed: true), 0)
        XCTAssertEqual(GateProcessExit.code(passed: false), 3)
    }

    func testGateFailureArtifactIsWrittenBeforeNonzeroOutcome() throws {
        struct Artifact: Codable, Equatable { let passed: Bool }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reborn-gate-\(UUID().uuidString).json")
            .path

        let code = try GateOutputWriter.write(
            Artifact(passed: false),
            to: path,
            passed: false
        )
        let decoded = try JSONDecoder().decode(
            Artifact.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )

        XCTAssertEqual(code, 3)
        XCTAssertEqual(decoded, Artifact(passed: false))
    }
}
