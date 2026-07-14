import Foundation

public struct GetAccountRateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: RateLimitSnapshot
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    public init(
        rateLimits: RateLimitSnapshot,
        rateLimitsByLimitId: [String: RateLimitSnapshot]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }
}

public struct RateLimitSnapshot: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?

    public init(
        limitId: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil
    ) {
        self.limitId = limitId
        self.primary = primary
        self.secondary = secondary
    }
}

public struct RateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Int32
    public let windowDurationMins: Int64?
    public let resetsAt: Int64?

    public init(usedPercent: Int32, windowDurationMins: Int64?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}
