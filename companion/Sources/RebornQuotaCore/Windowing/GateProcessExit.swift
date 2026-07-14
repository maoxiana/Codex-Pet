import Foundation

public enum GateProcessExit {
    public static func code(passed: Bool) -> Int32 {
        passed ? 0 : 3
    }
}

public enum GateOutputWriter {
    public static func write<Artifact: Encodable>(
        _ artifact: Artifact,
        to path: String,
        passed: Bool
    ) throws -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return GateProcessExit.code(passed: passed)
    }
}
