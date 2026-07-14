public enum FollowLatencyTiming {
    public static func origins(
        pollStartedAt: Double,
        axEventTimestamps: [Double],
        boundsMoved: Bool
    ) -> [Double] {
        if !axEventTimestamps.isEmpty {
            return axEventTimestamps
        }
        return boundsMoved ? [pollStartedAt] : []
    }

    public static func milliseconds(
        origins: [Double],
        committedAt: Double
    ) -> [Double] {
        origins.map { max(0, committedAt - $0) * 1_000 }
    }
}
