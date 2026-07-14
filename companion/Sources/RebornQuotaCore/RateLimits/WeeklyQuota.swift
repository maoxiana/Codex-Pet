import Foundation

public struct WeeklyQuota: Equatable, Sendable {
    public let remainingPercent: Int
    public let resetsAt: Date?
    public let fingerprint: String

    public init(remainingPercent: Int, resetsAt: Date?, fingerprint: String) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.fingerprint = fingerprint
    }
}

public struct WeeklyQuotaExtraction: Equatable, Sendable {
    public let quota: WeeklyQuota?
    public let warnings: [String]

    public init(quota: WeeklyQuota?, warnings: [String]) {
        self.quota = quota
        self.warnings = warnings
    }
}

public enum WeeklyQuotaExtractor {
    private static let weeklyWindowDurationMins: Int64 = 10_080
    private static let bothWeeklyWarning =
        "Both primary and secondary rate-limit windows are weekly; selected secondary."

    public static func extract(from response: GetAccountRateLimitsResponse) -> WeeklyQuotaExtraction {
        let selectedLimit: (effectiveId: String?, snapshot: RateLimitSnapshot)
        if let codexSnapshot = response.rateLimitsByLimitId?["codex"] {
            selectedLimit = ("codex", codexSnapshot)
        } else {
            selectedLimit = (response.rateLimits.limitId, response.rateLimits)
        }

        let primary = weeklyWindow(from: selectedLimit.snapshot.primary)
        let secondary = weeklyWindow(from: selectedLimit.snapshot.secondary)

        let selectedWindow: (name: String, value: RateLimitWindow)
        var warnings: [String] = []
        switch (primary, secondary) {
        case (_, let secondary?):
            selectedWindow = ("secondary", secondary)
            if primary != nil {
                warnings.append(bothWeeklyWarning)
            }
        case (let primary?, nil):
            selectedWindow = ("primary", primary)
        case (nil, nil):
            return WeeklyQuotaExtraction(quota: nil, warnings: [])
        }

        let usedPercent = Int64(selectedWindow.value.usedPercent)
        let remaining = min(max(Int64(100) - usedPercent, 0), 100)
        let resetsAt = selectedWindow.value.resetsAt.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let resetFingerprint = selectedWindow.value.resetsAt.map(String.init) ?? "null"
        let fingerprint = [
            fingerprintIdentity(for: selectedLimit.effectiveId),
            selectedWindow.name,
            "used=\(selectedWindow.value.usedPercent)",
            "reset=\(resetFingerprint)",
        ].joined(separator: "|")

        return WeeklyQuotaExtraction(
            quota: WeeklyQuota(
                remainingPercent: Int(remaining),
                resetsAt: resetsAt,
                fingerprint: fingerprint
            ),
            warnings: warnings
        )
    }

    private static func weeklyWindow(from window: RateLimitWindow?) -> RateLimitWindow? {
        guard window?.windowDurationMins == weeklyWindowDurationMins else {
            return nil
        }
        return window
    }

    private static func fingerprintIdentity(for limitId: String?) -> String {
        guard let limitId else {
            return "limitId=nil"
        }
        return "limitId=value:\(limitId.utf8.count):\(limitId)"
    }
}
