// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RebornQuotaCompanion",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RebornQuotaCore", targets: ["RebornQuotaCore"]),
        .executable(name: "RebornWindowProbe", targets: ["RebornWindowProbe"]),
        .executable(name: "RebornRateLimitProbe", targets: ["RebornRateLimitProbe"]),
        .executable(name: "RebornQuotaCompanion", targets: ["RebornQuotaCompanion"]),
    ],
    targets: [
        .target(name: "RebornQuotaCore"),
        .executableTarget(name: "RebornWindowProbe", dependencies: ["RebornQuotaCore"]),
        .executableTarget(name: "RebornRateLimitProbe", dependencies: ["RebornQuotaCore"]),
        .executableTarget(
            name: "RebornQuotaCompanion",
            dependencies: ["RebornQuotaCore"],
            resources: [.copy("Resources/gate-result.json")]
        ),
        .testTarget(name: "RebornQuotaCoreTests", dependencies: ["RebornQuotaCore"], resources: [.copy("Fixtures")]),
    ]
)
