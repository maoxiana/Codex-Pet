import Foundation

public enum EvaluationOptionsError: Error, Equatable, Sendable, CustomStringConvertible {
    case deferralFlagRequired
    case deferralNoteRequired
    case duplicateArgument(String)
    case missingArgument(String)
    case missingValue(String)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .deferralFlagRequired:
            return "--deferral-note requires --defer-performance"
        case .deferralNoteRequired:
            return "--defer-performance requires a nonempty --deferral-note"
        case .duplicateArgument(let argument):
            return "Duplicate argument: \(argument)"
        case .missingArgument(let argument):
            return "Missing required option \(argument)"
        case .missingValue(let argument):
            return "Missing value for \(argument)"
        case .unknownArgument(let argument):
            return "Unknown option for evaluate: \(argument)"
        }
    }
}

public struct EvaluationOptions: Equatable, Sendable {
    public let snapshotsDirectory: String
    public let metricsDirectory: String
    public let outputPath: String
    public let deferPerformance: Bool
    public let deferralNote: String?

    public init(
        snapshotsDirectory: String,
        metricsDirectory: String,
        outputPath: String,
        deferPerformance: Bool,
        deferralNote: String?
    ) {
        self.snapshotsDirectory = snapshotsDirectory
        self.metricsDirectory = metricsDirectory
        self.outputPath = outputPath
        self.deferPerformance = deferPerformance
        self.deferralNote = deferralNote
    }

    public static func parse(arguments: [String]) throws -> EvaluationOptions {
        var values: [String: String] = [:]
        var deferPerformance = false
        var index = 0
        let valuedOptions: Set<String> = [
            "--snapshots-dir",
            "--metrics-dir",
            "--output",
            "--deferral-note",
        ]

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--defer-performance" {
                guard !deferPerformance else {
                    throw EvaluationOptionsError.duplicateArgument(argument)
                }
                deferPerformance = true
                index += 1
                continue
            }
            guard valuedOptions.contains(argument) else {
                throw EvaluationOptionsError.unknownArgument(argument)
            }
            guard values[argument] == nil else {
                throw EvaluationOptionsError.duplicateArgument(argument)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count,
                  !arguments[valueIndex].hasPrefix("--") else {
                throw EvaluationOptionsError.missingValue(argument)
            }
            values[argument] = arguments[valueIndex]
            index += 2
        }

        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw EvaluationOptionsError.missingArgument(key)
            }
            return value
        }

        let rawNote = values["--deferral-note"]
        let note = rawNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        if deferPerformance, note?.isEmpty != false {
            throw EvaluationOptionsError.deferralNoteRequired
        }
        if !deferPerformance, rawNote != nil {
            throw EvaluationOptionsError.deferralFlagRequired
        }
        return EvaluationOptions(
            snapshotsDirectory: try required("--snapshots-dir"),
            metricsDirectory: try required("--metrics-dir"),
            outputPath: try required("--output"),
            deferPerformance: deferPerformance,
            deferralNote: note
        )
    }
}

public struct GateDecision: Equatable, Sendable {
    public let passed: Bool
    public let identificationPassed: Bool
    public let performanceVerified: Bool
    public let performanceDeferred: Bool
    public let deferralNote: String?

    public init(
        passed: Bool,
        identificationPassed: Bool,
        performanceVerified: Bool,
        performanceDeferred: Bool,
        deferralNote: String?
    ) {
        self.passed = passed
        self.identificationPassed = identificationPassed
        self.performanceVerified = performanceVerified
        self.performanceDeferred = performanceDeferred
        self.deferralNote = deferralNote
    }
}

public enum GateDecisionPolicy {
    public static func decide(
        identificationPassed: Bool,
        performanceVerified: Bool,
        deferPerformance: Bool,
        deferralNote: String?
    ) -> GateDecision {
        let deferred = deferPerformance && !performanceVerified
        return GateDecision(
            passed: identificationPassed && (performanceVerified || deferPerformance),
            identificationPassed: identificationPassed,
            performanceVerified: performanceVerified,
            performanceDeferred: deferred,
            deferralNote: deferPerformance ? deferralNote : nil
        )
    }
}

public enum PerformanceAcceptancePolicy {
    public static let maximumMovementDetectionMilliseconds = 100.0
    public static let maximumFollowLatencyMilliseconds = 34.0
    public static let maximumExclusiveIdleCPUPercent = 1.0
    public static let maximumExclusiveMovingCPUPercent = 5.0

    public static func acceptsMovementDetection(milliseconds: Double) -> Bool {
        milliseconds.isFinite
            && milliseconds >= 0
            && milliseconds <= maximumMovementDetectionMilliseconds
    }

    public static func acceptsFollowLatency(milliseconds: Double) -> Bool {
        milliseconds.isFinite
            && milliseconds >= 0
            && milliseconds <= maximumFollowLatencyMilliseconds
    }

    public static func acceptsIdleCPU(percent: Double) -> Bool {
        percent.isFinite
            && percent >= 0
            && percent < maximumExclusiveIdleCPUPercent
    }

    public static func acceptsMovingCPU(percent: Double) -> Bool {
        percent.isFinite
            && percent >= 0
            && percent < maximumExclusiveMovingCPUPercent
    }

    public static func accepts(
        maxMovementDetectionMs: Double,
        maxFollowLatencyMs: Double,
        idleCPUPercent: Double,
        movingCPUPercent: Double
    ) -> Bool {
        acceptsMovementDetection(milliseconds: maxMovementDetectionMs)
            && acceptsFollowLatency(milliseconds: maxFollowLatencyMs)
            && acceptsIdleCPU(percent: idleCPUPercent)
            && acceptsMovingCPU(percent: movingCPUPercent)
    }
}
