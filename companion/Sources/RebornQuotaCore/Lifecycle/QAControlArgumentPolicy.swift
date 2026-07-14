import Foundation

public enum QAControlArgumentPolicy {
    public static let maximumRestartDelaySeconds: Double = 86_400

    public static func restartDelaySeconds(_ value: String) -> Double? {
        guard let seconds = Double(value),
              seconds.isFinite,
              seconds >= 0,
              seconds <= maximumRestartDelaySeconds else { return nil }
        return seconds
    }
}
