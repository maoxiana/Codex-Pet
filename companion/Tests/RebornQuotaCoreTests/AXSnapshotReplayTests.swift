import Foundation
import XCTest
@testable import RebornQuotaCore

final class AXSnapshotReplayTests: XCTestCase {
    private struct Document: Decodable {
        let windows: [WindowSnapshot]
    }

    func testAXRuntimeEnvelopeReplaysAllKnownPresenceSnapshots() throws {
        let discriminator = try load(PetDiscriminator.self, name: "discriminator.json")

        for name in ["pet-visible", "pet-moved", "pet-resized", "secondary-display"] {
            let snapshot = try load(Document.self, name: "\(name).json")
            XCTAssertEqual(
                snapshot.windows.filter(discriminator.matchesAXEnvelope).count,
                1,
                name
            )
        }
    }

    func testStrictCGRulesReplayKnownAbsenceSnapshots() throws {
        let discriminator = try load(PetDiscriminator.self, name: "discriminator.json")

        for name in ["pet-hidden", "small-codex-window"] {
            let snapshot = try load(Document.self, name: "\(name).json")
            XCTAssertEqual(snapshot.windows.filter(discriminator.matches).count, 0, name)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qa/window-probe")
            .appendingPathComponent(name)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
