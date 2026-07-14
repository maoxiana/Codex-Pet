public enum AXTrustCheckMode: Equatable, Sendable {
    case passive
    case prompt
}

public enum AXSnapshotOptionsError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateArgument(String)
    case missingOutput
    case missingValue(String)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .duplicateArgument(let argument):
            return "Duplicate argument: \(argument)"
        case .missingOutput:
            return "Missing required option --output"
        case .missingValue(let argument):
            return "Missing value for \(argument)"
        case .unknownArgument(let argument):
            return "Unknown option for ax-snapshot: \(argument)"
        }
    }
}

public struct AXSnapshotOptions: Equatable, Sendable {
    public let outputPath: String
    public let trustCheckMode: AXTrustCheckMode

    public init(outputPath: String, trustCheckMode: AXTrustCheckMode) {
        self.outputPath = outputPath
        self.trustCheckMode = trustCheckMode
    }

    public static func parse(arguments: [String]) throws -> AXSnapshotOptions {
        var outputPath: String?
        var trustCheckMode = AXTrustCheckMode.passive
        var sawPrompt = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--prompt":
                guard !sawPrompt else {
                    throw AXSnapshotOptionsError.duplicateArgument("--prompt")
                }
                sawPrompt = true
                trustCheckMode = .prompt
                index += 1

            case "--output":
                guard outputPath == nil else {
                    throw AXSnapshotOptionsError.duplicateArgument("--output")
                }
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--") else {
                    throw AXSnapshotOptionsError.missingValue("--output")
                }
                outputPath = arguments[valueIndex]
                index += 2

            default:
                throw AXSnapshotOptionsError.unknownArgument(arguments[index])
            }
        }

        guard let outputPath, !outputPath.isEmpty else {
            throw AXSnapshotOptionsError.missingOutput
        }
        return AXSnapshotOptions(
            outputPath: outputPath,
            trustCheckMode: trustCheckMode
        )
    }
}
