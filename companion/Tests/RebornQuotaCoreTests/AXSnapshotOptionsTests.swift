import XCTest
@testable import RebornQuotaCore

final class AXSnapshotOptionsTests: XCTestCase {
    func testDefaultsToPassiveTrustCheck() throws {
        let options = try AXSnapshotOptions.parse(arguments: [
            "--output", "qa/window-probe/ax-tree.json",
        ])

        XCTAssertEqual(options.outputPath, "qa/window-probe/ax-tree.json")
        XCTAssertEqual(options.trustCheckMode, .passive)
    }

    func testPromptFlagSelectsPromptingTrustCheck() throws {
        let options = try AXSnapshotOptions.parse(arguments: [
            "--prompt",
            "--output", "qa/window-probe/ax-tree.json",
        ])

        XCTAssertEqual(options.outputPath, "qa/window-probe/ax-tree.json")
        XCTAssertEqual(options.trustCheckMode, .prompt)
    }

    func testRejectsUnknownOption() {
        XCTAssertThrowsError(try AXSnapshotOptions.parse(arguments: [
            "--output", "qa/window-probe/ax-tree.json",
            "--unknown",
        ])) { error in
            XCTAssertEqual(error as? AXSnapshotOptionsError, .unknownArgument("--unknown"))
        }
    }
}
