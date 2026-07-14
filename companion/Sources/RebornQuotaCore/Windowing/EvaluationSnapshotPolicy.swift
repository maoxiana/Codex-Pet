public enum EvaluationSnapshotPolicy {
    public static let requiredStructuralSnapshots = [
        "pet-hidden.json",
        "pet-visible.json",
        "pet-moved.json",
        "pet-resized.json",
        "notification-open.json",
        "small-codex-window.json",
        "ordinary-space-switch.json",
        "fullscreen-space.json",
    ]

    public static let secondaryDisplaySnapshot = "secondary-display.json"

    public static func requiredSnapshots(
        screenCountsBySnapshot: [String: Int]
    ) -> [String] {
        var required = requiredStructuralSnapshots
        if screenCountsBySnapshot.values.contains(where: { $0 > 1 }) {
            required.append(secondaryDisplaySnapshot)
        }
        return required
    }

    public static func missingSnapshots(
        existingNames: Set<String>,
        screenCountsBySnapshot: [String: Int]
    ) -> [String] {
        requiredSnapshots(screenCountsBySnapshot: screenCountsBySnapshot)
            .filter { !existingNames.contains($0) }
    }
}
