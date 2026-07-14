import Foundation
import RebornQuotaCore

private func runOneShotProbe() async -> CodexRateLimitProbeOutput {
    guard CommandLine.arguments.dropFirst() == ["--once", "--json"] else {
        return .unavailable
    }

    do {
        let executable = try await CodexExecutableLocator().locate()
        let extraction = try await CodexRateLimitClient().fetchOnce(executable: executable)
        return CodexRateLimitProbeOutput(extraction: extraction)
    } catch {
        return .unavailable
    }
}

let output = await runOneShotProbe()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let fallback = Data(
    #"{"durationMins":null,"hasResetTime":false,"limitId":null,"remainingPercent":null,"status":"unavailable"}"#.utf8
)
var line = (try? encoder.encode(output)) ?? fallback
line.append(0x0A)
FileHandle.standardOutput.write(line)
