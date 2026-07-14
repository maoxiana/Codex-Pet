# Reborn Quota Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install a lightweight native macOS companion that reads Codex’s real weekly rate limit and renders a compact, expandable quota bubble anchored to the floating Reborn pet.

**Architecture:** A Swift package contains a testable core library, a window-feasibility probe, and an `LSUIElement` AppKit/SwiftUI executable. The executable owns a Codex App Server child process, converts the 10080-minute limit window into a small view model, locates the Codex pet window without modifying `ChatGPT.app`, and positions a non-activating transparent panel above or below the pet. Installation produces an ad-hoc-signed app bundle and an idempotent per-user LaunchAgent.

**Tech Stack:** Swift 6.2, Swift Package Manager, Foundation, AppKit, SwiftUI, XCTest, Codex App Server line-delimited JSON protocol, launchd.

**Design spec:** `docs/superpowers/specs/2026-07-13-reborn-quota-companion-design.md`

**Repository note:** `/Users/maoxian/Work/reborn-transformation-gun-run` is not currently a Git repository. Do not initialize or mutate Git metadata merely to satisfy checkpoint steps. After each task, run the listed verification and record completion in this plan; commit only if the user later places the directory under Git.

**Command convention:** Every verification command is self-contained and starts with `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion` (or uses an absolute path). Do not rely on a previous step's shell working directory.

**Pre-execution baseline (must run before Task 1):** Preserve evidence that this companion never mutates the installed or packaged Reborn pet. Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run
shasum -a 256 \
  /Users/maoxian/.codex/pets/reborn/pet.json \
  /Users/maoxian/.codex/pets/reborn/spritesheet.webp \
  /Users/maoxian/Work/codex-pet-v2-package/reborn/pet.json \
  /Users/maoxian/Work/codex-pet-v2-package/reborn/spritesheet.webp \
  > qa/reborn-quota-companion-baseline.sha256
```

Expected: four hashes are recorded before any companion file is created.

---

## File Map

Create all implementation files under `/Users/maoxian/Work/reborn-transformation-gun-run/companion`:

```text
companion/
  Package.swift                         Swift package and macOS 15 minimum target
  ProtocolSchemas/0.144.0-alpha.4/      Pinned generated protocol subset + SHA256SUMS
  Sources/RebornQuotaCore/
    CoreVersion.swift                   Permanent package/client version
    RateLimits/RateLimitPayload.swift   Codable App Server rate-limit DTOs
    RateLimits/WeeklyQuota.swift        Domain model and weekly-window extraction
    RateLimits/QuotaRefreshMachine.swift Single-flight refresh/freshness state machine
    RateLimits/QuotaPresentationFormatter.swift Deterministic user-visible copy/time formatting
    AppServer/JSONLineTransport.swift   Framing, request correlation, stderr drain
    AppServer/CodexExecutableLocator.swift Absolute executable discovery and validation
    AppServer/CodexRateLimitClient.swift Initialize/read/invalidation/reconnect orchestration
    Windowing/WindowSnapshot.swift      Testable window metadata and provider protocol
    Windowing/PetWindowDiscriminator.swift Stable Reborn candidate selection
    Windowing/CoordinateConverter.swift Explicit CG/AppKit multi-screen conversion
    Windowing/BubblePlacement.swift     Coordinate conversion and locked-side placement
    Windowing/PanelInteractionState.swift Pure hover/click/pin behavior
    Lifecycle/LifecycleState.swift      Host/app-server lifecycle transitions
    Lifecycle/PermissionState.swift     One-time AX rationale/denial/recheck policy
    Lifecycle/CrashLoopGuard.swift      Persisted launch failure throttling
  Sources/RebornWindowProbe/main.swift  Feasibility-spike metadata sampler
  Sources/RebornRateLimitProbe/main.swift Normalized one-shot App Server probe
  Sources/RebornQuotaCompanion/
    main.swift                          Agent app entry point
    AppDelegate.swift                   Lifecycle, single instance, host observation
    SingleInstanceLock.swift            Per-user process lock
    PermissionCoordinator.swift         AX request and Settings routing when required
    PetWindowLocator.swift              Live CG/AX provider and adaptive tracking
    QuotaPanelController.swift          Non-activating NSPanel and mouse interaction
    QuotaBubbleView.swift               Compact/expanded SwiftUI presentation
  Tests/RebornQuotaCoreTests/
    Fixtures/*.json                     Exact generated-schema payload samples
    WeeklyQuotaTests.swift
    QuotaRefreshMachineTests.swift
    JSONLineTransportTests.swift
    CodexRateLimitClientTests.swift
    PetWindowDiscriminatorTests.swift
    CoordinateConverterTests.swift
    BubblePlacementTests.swift
    QuotaPresentationFormatterTests.swift
    PanelInteractionStateTests.swift
    PermissionStateTests.swift
    AppLifecycleStateTests.swift
    CrashLoopGuardTests.swift
  scripts/pin_protocol_schema.sh        Reproducible CLI schema subset/checksum capture
  scripts/build_app.sh                  Release build, bundle assembly, ad-hoc signing
  scripts/install_app.sh                Idempotent per-user install and bootstrap
  scripts/uninstall_app.sh              Idempotent bootout and removal
  qa/window-probe/gate-result.json       Machine-readable CG/AX feasibility decision
  Resources/Info.plist                  LSUIElement app metadata
  Resources/com.maoxian.reborn-quota.plist.template
  dist/RebornQuota.app                  Generated output, not source of truth
```

Keep each file focused on the responsibility listed above. Core types must not import AppKit unless they model `CGRect`/`NSScreen` conversion through plain value types; production frameworks are adapted at the executable boundary.

### Task 1: Bootstrap the Swift package

**Files:**
- Create: `companion/Package.swift`
- Create: `companion/Sources/RebornQuotaCore/CoreVersion.swift`
- Create: `companion/Sources/RebornWindowProbe/main.swift`
- Create: `companion/Sources/RebornRateLimitProbe/main.swift`
- Create: `companion/Sources/RebornQuotaCompanion/main.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/BootstrapTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/Fixtures/placeholder.json`

- [x] **Step 1: Write the failing package smoke test**

```swift
import XCTest
@testable import RebornQuotaCore

final class BootstrapTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(RebornQuotaCoreVersion.current, "0.1.0")
    }
}
```

- [x] **Step 2: Create the package skeleton required for SwiftPM evaluation**

Create `Package.swift`, `Fixtures/placeholder.json` containing `{}`, an empty `CoreVersion.swift`, and three executable `main.swift` stubs that print a temporary startup line and exit. These files must exist before running SwiftPM so package evaluation succeeds and the intended missing-symbol failure can be observed.

Use one library and three executables:

Use macOS 15 and these products/targets:

```swift
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
        .executableTarget(name: "RebornQuotaCompanion", dependencies: ["RebornQuotaCore"]),
        .testTarget(name: "RebornQuotaCoreTests", dependencies: ["RebornQuotaCore"], resources: [.copy("Fixtures")]),
    ]
)
```

- [x] **Step 3: Run the smoke test and confirm it fails**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter BootstrapTests`

Expected: FAIL because `RebornQuotaCoreVersion` does not exist.

- [x] **Step 4: Add only the minimal module version implementation**

```swift
public enum RebornQuotaCoreVersion {
    public static let current = "0.1.0"
}
```

Put the version in permanent `CoreVersion.swift`. Do not change the already-compiling executable stubs in this GREEN step.

- [x] **Step 5: Run the complete suite**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test`

Expected: PASS, 1 test.

- [x] **Step 6: Record checkpoint**

Mark Task 1 complete in this plan. No Git commit is possible in the current non-repository directory.

### Task 2: Prove pet-window tracking with a release-mode harness

> **User-approved execution change (2026-07-13):** After all structural snapshots, a trusted AX tree, and a unique AX-assisted discriminator were captured, the user explicitly asked to stop the remaining long timed scenarios and continue implementation. Keep strict evaluation available and failing when metrics are absent, but allow an explicit `--defer-performance --deferral-note <text>` development result. Such a result must expose `identificationPassed=true`, `performanceVerified=false`, `performanceDeferred=true`, null metrics, and warnings; it must never imply that latency/CPU thresholds were measured. Runtime selection remains fail-closed on missing or ambiguous CG/AX identity.

**Files:**
- Create: `companion/Sources/RebornQuotaCore/Windowing/WindowSnapshot.swift`
- Create: `companion/Sources/RebornQuotaCore/Windowing/CoordinateConverter.swift`
- Modify: `companion/Sources/RebornWindowProbe/main.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/CoordinateConverterTests.swift`
- Create: `companion/qa/window-probe/README.md`
- Create from probe: `companion/qa/window-probe/*.json`

- [x] **Step 1: Write failing coordinate-conversion tests**

Test CG top-left coordinates to AppKit bottom-left coordinates for a primary screen, negative-origin left screen, above/below screen layouts, mixed visible frames, and Retina displays. Pixel scale must not be applied twice because CG window bounds and AppKit points are compared in global logical coordinates after explicit screen selection.

- [x] **Step 2: Verify RED**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter CoordinateConverterTests`

Expected: FAIL because `CoordinateConverter` does not exist.

- [x] **Step 3: Implement tolerant metadata and continuous harness**

`CGWindowListCopyWindowInfo` supplies owner PID/name but not bundle id. Resolve bundle id via `NSRunningApplication(processIdentifier:)` and retain only PIDs whose bundle id is `com.openai.codex`. Treat `kCGWindowSharingState`, alpha, title, and other privacy-filtered fields as optional; never require protected metadata or Screen Recording permission.

Use an explicitly tolerant value type:

```swift
public struct WindowSnapshot: Codable, Equatable, Sendable {
    public let ownerPID: Int32
    public let resolvedBundleID: String?
    public let ownerName: String?
    public let layer: Int
    public let bounds: RectValue
    public let alpha: Double?
    public let isOnScreen: Bool?
    public let sharingState: Int?
    public let title: String?
    public let order: Int
}
```

The release-mode probe supports exact commands:

```text
RebornWindowProbe snapshot --state <name> --output <file>
RebornWindowProbe track --duration-seconds <n> --panel --metrics-out <file>
RebornWindowProbe ax-snapshot --output <file>
RebornWindowProbe evaluate --snapshots-dir <dir> --metrics-dir <dir> --output <file>
```

`track` renders a small colored non-activating panel at candidate `layer + 1`, polls at 10Hz idle/60Hz moving, and records candidate count, movement-detection latency, per-frame follow latency, loop CPU time, wall time, screen id, layer, and Space/full-screen visibility transitions. It captures metadata only, never pixels.

- [x] **Step 4: Build the release harness**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift build -c release --product RebornWindowProbe`

Expected: PASS and `.build/release/RebornWindowProbe` exists.

- [x] **Step 5: Capture named snapshots with exact commands**

Run one command after placing Codex/Reborn in each named state:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
.build/release/RebornWindowProbe snapshot --state pet-hidden --output qa/window-probe/pet-hidden.json
.build/release/RebornWindowProbe snapshot --state pet-visible --output qa/window-probe/pet-visible.json
.build/release/RebornWindowProbe snapshot --state pet-moved --output qa/window-probe/pet-moved.json
.build/release/RebornWindowProbe snapshot --state pet-resized --output qa/window-probe/pet-resized.json
.build/release/RebornWindowProbe snapshot --state notification-open --output qa/window-probe/notification-open.json
.build/release/RebornWindowProbe snapshot --state small-codex-window --output qa/window-probe/small-codex-window.json
.build/release/RebornWindowProbe snapshot --state ordinary-space-switch --output qa/window-probe/ordinary-space-switch.json
.build/release/RebornWindowProbe snapshot --state fullscreen-space --output qa/window-probe/fullscreen-space.json
```

If a second display exists, also capture `secondary-display.json`; otherwise record `not-available` in README and cover the geometry with tests.

- [x] **Step 6: Derive a provisional discriminator from snapshots**

Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
.build/release/RebornWindowProbe derive \
  --hidden qa/window-probe/pet-hidden.json \
  --visible qa/window-probe/pet-visible.json \
  --exclude qa/window-probe/notification-open.json \
  --exclude qa/window-probe/small-codex-window.json \
  --output qa/window-probe/discriminator.json
```

Expected: exactly one candidate in visible/moved/resized fixtures and zero in hidden/excluded fixtures, using only PID-resolved bundle id, layer, bounds, and on-screen ordering.

If CG metadata alone is ambiguous, run the explicit AX-tree probe before failing the gate:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
.build/release/RebornWindowProbe ax-snapshot --output qa/window-probe/ax-tree.json
```

Record only roles, subroles, identifiers, geometry, parent/child relationships, and notification support—never text content. If this requires Accessibility permission, request it only for the release probe. Derive an AX-assisted discriminator only when the tree exposes a stable pet-specific relationship; otherwise stop before rendering a panel.

- [x] **Step 7: Measure tracking and panel layering (explicitly deferred by user; strict mode remains unverified)**

Run while dragging Reborn repeatedly for 30 seconds, then explicitly exercise coverage, hiding, ordinary Space switching, and a fullscreen Space. Every invocation renders the candidate panel so its collection behavior is measured with the pet:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
.build/release/RebornWindowProbe track --scenario dragging --duration-seconds 30 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/tracking.json
.build/release/RebornWindowProbe track --scenario covered --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/covered.json
.build/release/RebornWindowProbe track --scenario pet-hidden --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/pet-hidden-track.json
.build/release/RebornWindowProbe track --scenario ordinary-space-switch --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/ordinary-space-track.json
.build/release/RebornWindowProbe track --scenario fullscreen-space --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/fullscreen-space-track.json
```

Expected JSON: `stableCandidate=true`, `maxMovementDetectionMs<=100`, `maxFollowLatencyMs<=34`, `idleCPUPercent<1`, `movingCPUPercent<5`, `panelAbovePet=true`, and no panel residue when the pet is hidden or on a Space where it is absent. The maximum—not p95—moving follow latency is the acceptance criterion.

- [x] **Step 8: Emit, document, and enforce the machine-readable gate**

Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
.build/release/RebornWindowProbe evaluate \
  --snapshots-dir qa/window-probe \
  --metrics-dir qa/window-probe \
  --output qa/window-probe/gate-result.json
```

The result must include at least:

```json
{
  "passed": true,
  "requiresAX": false,
  "petLayer": 0,
  "discriminator": {},
  "maxMovementDetectionMs": 0,
  "maxFollowLatencyMs": 0,
  "idleCPUPercent": 0,
  "movingCPUPercent": 0
}
```

Write the observed PID/bundle mapping, layer, unprotected size/order discriminator, AX exposure (if inspected), ordinary/full-screen Space behavior, panel collection behavior, and metrics to README. Tasks 6–8 must parse this exact result instead of restating assumptions. If `passed` is false, stable discrimination fails, or any metric fails, stop all later tasks and report the blocker. Do not patch/re-sign `ChatGPT.app` and do not implement quota/UI code.

- [x] **Step 9: Record checkpoint**

Mark Task 2 pass/fail with evidence paths.

### Task 3: Parse and select the weekly limit window

**Files:**
- Create: `companion/Sources/RebornQuotaCore/RateLimits/RateLimitPayload.swift`
- Create: `companion/Sources/RebornQuotaCore/RateLimits/WeeklyQuota.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/Fixtures/rate-limits-secondary-weekly.json`
- Create: `companion/Tests/RebornQuotaCoreTests/Fixtures/rate-limits-primary-weekly.json`
- Create: `companion/Tests/RebornQuotaCoreTests/Fixtures/rate-limits-no-weekly.json`
- Create: `companion/Tests/RebornQuotaCoreTests/WeeklyQuotaTests.swift`

- [x] **Step 1: Write failing tests for exact window semantics**

Tests must cover:

```swift
func testSelectsSecondary10080MinuteWindowAndConvertsUsedToRemaining()
func testFallsBackToPrimaryWhenOnlyPrimaryIsWeekly()
func testPrefersSecondaryAndEmitsWarningWhenBothAreWeekly()
func testRejectsNullDurationAndNonWeeklyDurations()
func testClampsRemainingPercentToZeroThroughOneHundred()
func testAllowsMissingResetTime()
func testPrefersRateLimitsByCodexIdOverCompatibilitySnapshot()
```

Use exact JSON keys from the generated `GetAccountRateLimitsResponse` schema: `rateLimits`, `rateLimitsByLimitId`, `primary`, `secondary`, `usedPercent`, `windowDurationMins`, and `resetsAt`.

- [x] **Step 2: Run the focused tests and confirm failure**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter WeeklyQuotaTests`

Expected: compile failure because DTOs and `WeeklyQuotaExtractor` are missing.

- [x] **Step 3: Implement tolerant Codable DTOs and extractor**

Expose this API:

```swift
public struct WeeklyQuota: Equatable, Sendable {
    public let remainingPercent: Int
    public let resetsAt: Date?
    public let fingerprint: String
}

public struct WeeklyQuotaExtraction: Equatable, Sendable {
    public let quota: WeeklyQuota?
    public let warnings: [String]
}

public enum WeeklyQuotaExtractor {
    public static func extract(from response: GetAccountRateLimitsResponse) -> WeeklyQuotaExtraction
}
```

Unknown JSON fields must decode successfully. Do not infer a weekly window when duration is null. Build the fingerprint from selected limit id, `primary|secondary`, `usedPercent`, and `resetsAt`.

- [x] **Step 4: Run focused and full tests**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter WeeklyQuotaTests && swift test`

Expected: PASS.

- [x] **Step 5: Record checkpoint**

Mark Task 3 complete with test count and commands.

### Task 4: Implement freshness, presentation, and single-flight refresh state

**Files:**
- Create: `companion/Sources/RebornQuotaCore/RateLimits/QuotaRefreshMachine.swift`
- Create: `companion/Sources/RebornQuotaCore/RateLimits/QuotaPresentationFormatter.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/QuotaRefreshMachineTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/QuotaPresentationFormatterTests.swift`

- [x] **Step 1: Write failing actor/state-machine tests**

Cover:

```swift
func testOnlyOneReadIsInFlight()
func testNotificationsDuringReadCoalesceIntoOneFollowUp()
func testResponseFromOldConnectionEpochIsDiscarded()
func testDirtyResponseDoesNotPublishBeforeFollowUp()
func testInitialExpiredSnapshotStartsRefreshingWithoutLastKnownData()
func testSameExpiredFingerprintTriggersOnlyOneImmediateRefresh()
func testRepeatedExpiredSnapshotsDoNotAdvanceGraceDeadline()
func testGraceExpiryBecomesUnavailableStaleSnapshot()
func testFreshSnapshotUpdatesLastUpdatedAt()
```

Also test deterministic presentation output for local-time reset formatting using an injected calendar/time zone, missing reset time, loading, stale/no-history copy, fresh/refreshing copy, a 140ms normal transition duration, and zero duration when reduced motion is enabled.

Inject a `ClockProtocol` and never sleep in tests.

- [x] **Step 2: Run and verify RED**

Run these separately so both RED suites are observed:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter QuotaRefreshMachineTests
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter QuotaPresentationFormatterTests
```

Expected: FAIL because the state machine is absent.

- [x] **Step 3: Implement the minimal deterministic API**

```swift
public enum QuotaDisplayState: Equatable, Sendable {
    case loading
    case available(WeeklyQuota, lastUpdatedAt: Date)
    case refreshing(lastKnown: WeeklyQuota?, since: Date)
    case noWeeklyWindow
    case unavailable(QuotaUnavailableReason)
}

public struct ReadToken: Equatable, Sendable {
    let connectionEpoch: UInt64
    let generation: UInt64
}

public actor QuotaRefreshMachine {
    public nonisolated var states: AsyncStream<QuotaDisplayState> { get }
    public func connectionStarted() -> UInt64
    public func invalidate(_ reason: RefreshReason) -> ReadToken?
    public func complete(_ token: ReadToken, result: Result<WeeklyQuotaExtraction, Error>) -> ReadToken?
    public func tick(now: Date) -> ReadToken?
}
```

Returning a token means the client should perform one read. A completion may return exactly one follow-up token when dirty. Publish every state transition through one replaying `AsyncStream<QuotaDisplayState>` so the UI can observe it. Keep the state machine transport-free. `QuotaPresentationFormatter` converts states into plain title/detail/progress/transition values and must not import SwiftUI.

- [x] **Step 4: Run focused and full tests**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter QuotaRefreshMachineTests && swift test --filter QuotaPresentationFormatterTests && swift test`

Expected: PASS with deterministic fake-clock coverage.

- [x] **Step 5: Record checkpoint**

Mark Task 4 complete.

### Task 5: Pin the protocol and build the Codex App Server transport/client

**Files:**
- Create: `companion/Sources/RebornQuotaCore/AppServer/JSONLineTransport.swift`
- Create: `companion/Sources/RebornQuotaCore/AppServer/CodexExecutableLocator.swift`
- Create: `companion/Sources/RebornQuotaCore/AppServer/CodexRateLimitClient.swift`
- Modify: `companion/Sources/RebornRateLimitProbe/main.swift`
- Create: `companion/scripts/pin_protocol_schema.sh`
- Create: `companion/ProtocolSchemas/0.144.0-alpha.4/SHA256SUMS`
- Create: `companion/Tests/RebornQuotaCoreTests/JSONLineTransportTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/CodexRateLimitClientTests.swift`

- [x] **Step 1: Write failing framing, discovery, and lifecycle tests**

Use injectable protocols:

```swift
public protocol LineProcess: Sendable {
    var stdoutLines: AsyncThrowingStream<Data, Error> { get }
    var stderrLines: AsyncStream<Data> { get }
    func writeLine(_ data: Data) async throws
    func terminate(grace: Duration) async
}

public protocol CodexProcessFactory: Sendable {
    func start(executable: URL) throws -> any LineProcess
}
```

Tests must verify initialize → initialized → rate-limit read order, `params: null`, request-id correlation, unknown notification tolerance, update-before-first-snapshot, duplicate/racing `account/rateLimits/updated` invalidations, 60-second refresh, exact 1/2/4/8/30-second reconnect delays, disconnect grace, error responses, timeouts, malformed lines, stderr draining, out-of-order responses, auth errors, hung-child termination, and no orphan process after cancellation. Inject clock/scheduler/process dependencies.

- [x] **Step 2: Verify RED**

Run separately:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter JSONLineTransportTests
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter CodexRateLimitClientTests
```

Expected: FAIL because transport/client types do not exist.

- [x] **Step 3: Pin the generated protocol schema reproducibly**

Implement and run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
./scripts/pin_protocol_schema.sh /Applications/ChatGPT.app/Contents/Resources/codex 0.144.0-alpha.4
shasum -a 256 -c ProtocolSchemas/0.144.0-alpha.4/SHA256SUMS
```

The script verifies `codex-cli 0.144.0-alpha.4`, runs `codex app-server generate-json-schema --experimental` in a temporary directory, copies only `JSONRPCMessage.json`, `JSONRPCResponse.json`, `JSONRPCError.json`, `JSONRPCErrorError.json`, `RequestId.json`, `ClientRequest.json`, `ClientNotification.json`, `ServerNotification.json`, `v1/InitializeParams.json`, `v1/InitializeResponse.json`, `v2/GetAccountRateLimitsResponse.json`, and `v2/AccountRateLimitsUpdatedNotification.json`, then writes SHA256SUMS. These generic envelope definitions are part of the pinned contract, not inferred by hand.

Compatibility policy: the pinned schema is the development contract. At runtime a different CLI version is allowed to attempt initialization because decoding tolerates unknown fields; it logs a version warning. Missing methods, invalid required response shapes, or initialization/read errors produce typed `incompatibleProtocol` and hide the quota. Never silently reinterpret another payload.

- [x] **Step 4: Implement executable discovery**

Candidates, in order:

```text
installer-provided `CODEX_CLI_PATH` absolute path (production configuration)
/Applications/ChatGPT.app/Contents/Resources/codex
~/Applications/ChatGPT.app/Contents/Resources/codex
PATH lookup (development only)
```

Validate executability and a 2-second `--version` probe. Tests must prove the installer-provided environment value wins over bundle fallbacks and that relative or non-executable values are rejected. Return a typed unavailable reason instead of spinning.

- [x] **Step 5: Implement line transport and client actor**

The concrete process command is `<absolute-codex-path> app-server --stdio`. Use Foundation `Process`, `Pipe`, `FileHandle.bytes.lines`, and JSONSerialization/Codable. The protocol message omits a mandatory `jsonrpc` field because the generated Codex schemas define `{id, method, params}` envelopes. Send:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"reborn-quota","title":"Reborn Quota","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}
{"method":"initialized"}
{"id":2,"method":"account/rateLimits/read","params":null}
```

Limit stderr memory to the last 64 KiB. Use 5s initialize, 8s read, and 2s shutdown deadlines.

- [x] **Step 6: Run tests and a read-only real protocol smoke check**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test`

Then run the defined one-shot executable, which prints only normalized fields and never auth/raw payloads:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
swift run RebornRateLimitProbe --once --json | tee qa/app-server-smoke.txt
```

Expected shape: `{"status":"available|noWeeklyWindow|unavailable","limitId":"codex|null","durationMins":10080|null,"remainingPercent":0...100|null,"hasResetTime":true|false}`.

Expected: tests PASS; real smoke check either reports one weekly window or a typed unavailable/no-weekly result.

- [x] **Step 7: Record checkpoint**

Mark Task 5 complete and preserve the normalized smoke result in `companion/qa/app-server-smoke.txt`.

### Task 6: Implement candidate selection and bubble geometry

**Files:**
- Create: `companion/Sources/RebornQuotaCore/Windowing/PetWindowDiscriminator.swift`
- Create: `companion/Sources/RebornQuotaCore/Windowing/BubblePlacement.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/PetWindowDiscriminatorTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/BubblePlacementTests.swift`

- [x] **Step 1: Write failing fixture-replay tests**

Parse `qa/window-probe/gate-result.json`, require `passed=true`, and replay every probe JSON with its exact recorded discriminator, layer, and `requiresAX` decision. Assert the documented candidate or nil. Add geometry tests for negative screen coordinates, mixed display arrangements, horizontal clamping, above placement, below placement with flipped arrow, neither-side hiding, and side locking across compact/expanded transitions.

- [x] **Step 2: Verify RED**

Run separately:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter PetWindowDiscriminatorTests
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter BubblePlacementTests
```

Expected: FAIL.

- [x] **Step 3: Implement only the observed discriminator**

Do not add generic “smallest window” heuristics. Decode the observed rule from `gate-result.json` and express that exact spike evidence as a scored or predicate-based discriminator with an ambiguity result. Ambiguous results must hide the bubble.

- [x] **Step 4: Implement expanded-envelope placement**

Expose:

```swift
public enum BubbleSide: Equatable, Sendable { case above, below }
public struct BubblePlacement: Equatable, Sendable {
    public let origin: PointValue
    public let side: BubbleSide
}

public enum BubblePlacementEngine {
    public static func choose(
        petFrame: RectValue,
        screenVisibleFrame: RectValue,
        expandedSize: SizeValue,
        gap: Double,
        lockedSide: BubbleSide?
    ) -> BubblePlacement?
}
```

- [x] **Step 5: Run focused and full tests**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter PetWindowDiscriminatorTests && swift test --filter BubblePlacementTests && swift test`

Expected: PASS.

- [x] **Step 6: Record checkpoint**

Mark Task 6 complete.

### Task 7: Build the live locator and non-activating quota panel

**Files:**
- Create: `companion/Sources/RebornQuotaCore/Windowing/PanelInteractionState.swift`
- Create: `companion/Sources/RebornQuotaCompanion/PetWindowLocator.swift`
- Create: `companion/Sources/RebornQuotaCompanion/QuotaPanelController.swift`
- Create: `companion/Sources/RebornQuotaCompanion/QuotaBubbleView.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/PanelInteractionStateTests.swift`

- [x] **Step 1: Write failing pure interaction-state tests**

Test hover expand/collapse, click pin/unpin, outside click, hide cleanup, reduced-motion duration, and side preservation. Keep these rules in a pure `PanelInteractionState` type in the core library.

- [x] **Step 2: Verify RED**

Run: `cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter PanelInteractionStateTests`

Expected: FAIL.

- [x] **Step 3: Implement the pure state and AppKit adapters**

Create a borderless clear `NSPanel` with:

```swift
panel.styleMask = [.borderless, .nonactivatingPanel]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
```

Override `canBecomeKey` to false. Set level from measured `petLayer + 1` within the safe range. Keep window bounds equal to visible bubble bounds.

- [x] **Step 4: Implement B-style SwiftUI content**

Collapsed: `本周剩余` plus orange `72%` in approximately `164×32pt`.

Expanded: title, percent, progress, and localized reset time in approximately `200×82pt`. Add explicit loading, refreshing, no-weekly, unavailable, and missing-reset copy. Use accessibility labels and respect `accessibilityReduceMotion`.

- [x] **Step 5: Implement locator cadence and permission degradation**

At startup, load the bundled copy of `qa/window-probe/gate-result.json`; refuse to show the panel if it is missing, fails validation, or records `passed=false`. Use its recorded discriminator, pet layer, and `requiresAX` value. Use AX moved/resized notifications only if the gate proved them reliable. Otherwise poll at 10Hz idle, switch to 60Hz on movement, and return to 10Hz after 300ms stable. Hide on ambiguity or missing pet. Own both local and global `NSEvent` mouse-monitor tokens explicitly and remove them on collapse, hide, and shutdown. Use mouse-only `NSEvent` monitors, never `CGEventTap`; this path must not request Input Monitoring. If a global monitor cannot be created, fall back to hover dismissal.

- [x] **Step 6: Run tests and build the real executable target**

Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
swift test
swift build --product RebornQuotaCompanion
```

Expected: tests and build PASS. Defer focus, Dock, Cmd-Tab, screenshots, and `.app` launch checks until Task 8 assembles the real bundle.

- [x] **Step 7: Record checkpoint**

Mark Task 7 complete with build/test output; do not claim UI runtime QA yet.

### Task 8: Wire application lifecycle, app bundle, and LaunchAgent scripts

**Files:**
- Create: `companion/Sources/RebornQuotaCore/Lifecycle/LifecycleState.swift`
- Create: `companion/Sources/RebornQuotaCore/Lifecycle/PermissionState.swift`
- Create: `companion/Sources/RebornQuotaCore/Lifecycle/CrashLoopGuard.swift`
- Create: `companion/Sources/RebornQuotaCompanion/AppDelegate.swift`
- Create: `companion/Sources/RebornQuotaCompanion/SingleInstanceLock.swift`
- Create: `companion/Sources/RebornQuotaCompanion/PermissionCoordinator.swift`
- Modify: `companion/Sources/RebornQuotaCompanion/main.swift`
- Create: `companion/Resources/Info.plist`
- Create: `companion/Resources/com.maoxian.reborn-quota.plist.template`
- Create: `companion/scripts/build_app.sh`
- Create: `companion/scripts/install_app.sh`
- Create: `companion/scripts/uninstall_app.sh`
- Create: `companion/Tests/RebornQuotaCoreTests/AppLifecycleStateTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/PermissionStateTests.swift`
- Create: `companion/Tests/RebornQuotaCoreTests/CrashLoopGuardTests.swift`

- [x] **Step 1: Write failing lifecycle-state tests**

Cover host absent/present/exited, app-server start only when host exists, child termination on host exit, single-instance rejection, monitor cleanup, and persisted crash counter/reset behavior. In `PermissionStateTests`, cover: no AX request when the spike did not require AX; one-time rationale before system prompt; persisted denial with no repeated prompt; 30-second recheck; later grant; Settings deep-link action; and degraded hidden state. These tests must exist before `PermissionCoordinator` is implemented.

- [x] **Step 2: Verify RED**

Run separately:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter AppLifecycleStateTests
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter PermissionStateTests
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && swift test --filter CrashLoopGuardTests
```

Expected: FAIL.

- [x] **Step 3: Implement app lifecycle, permission flow, and crash guard**

Use `NSWorkspace.shared.runningApplications` and launch/terminate notifications for bundle id `com.openai.codex`. Use a named local lock or per-user pid lock for single instance. Do not start Codex app-server while the host is absent.

Only instantiate `PermissionCoordinator` when the bundled Task 2 `gate-result.json` records `requiresAX=true`. Show a custom one-time rationale, then call `AXIsProcessTrustedWithOptions`; persist denial, recheck trust every 30 seconds without prompting, and provide the `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` route. If AX is required, document that every ad-hoc rebuild can change the code identity and invalidate TCC approval; stable bundle id/path alone do not guarantee retained permission, so final installation happens after build freeze and later upgrades may require re-approval.

Add a compile-time QA control guarded by `#if REBORN_QUOTA_QA`: `--qa-restart-child-after <seconds> --qa-report <absolute-file>`. It terminates only the companion-owned App Server child, records child PID/epoch before and after, waits for reconnect, writes a machine-readable report, and never targets Codex itself. Production builds must not recognize these arguments.

Persist the crash guard under `~/Library/Application Support/RebornQuota/runtime-state.json`: count failures occurring within 5 minutes, clear after 10 minutes healthy, and stop self-relaunch work after 3 rapid failures while launchd's 30-second throttle remains active. Inject storage and clock for tests.

- [x] **Step 4: Build bundle metadata**

`Info.plist` must include:

```xml
<key>CFBundleIdentifier</key><string>com.maoxian.reborn-quota</string>
<key>CFBundleName</key><string>RebornQuota</string>
<key>CFBundleExecutable</key><string>RebornQuotaCompanion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
```

- [x] **Step 5: Implement deterministic build and idempotent install scripts**

`build_app.sh` runs `swift build -c release`, obtains the executable directory from `swift build -c release --show-bin-path`, assembles `dist/RebornQuota.app`, copies `qa/window-probe/gate-result.json` into the bundle resources, renders a fully expanded staging LaunchAgent at `dist/com.maoxian.reborn-quota.plist`, and runs `codesign --force --deep --sign -`. When and only when `QA_BUILD=1`, it adds `-Xswiftc -DREBORN_QUOTA_QA`; default and installed builds never contain QA controls.

`install_app.sh` first resolves and validates the absolute Codex CLI path, expands all absolute paths, runs `launchctl bootout gui/$UID/com.maoxian.reborn-quota` tolerantly, copies into `~/Applications`, and renders this required LaunchAgent shape before `plutil -lint`, `launchctl bootstrap`, and `kickstart`:

```xml
<key>Label</key><string>com.maoxian.reborn-quota</string>
<key>ProgramArguments</key>
<array><string>/Users/USER/Applications/RebornQuota.app/Contents/MacOS/RebornQuotaCompanion</string></array>
<key>EnvironmentVariables</key>
<dict><key>CODEX_CLI_PATH</key><string>/Applications/ChatGPT.app/Contents/Resources/codex</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>30</integer>
```

The installer substitutes the real home directory and discovered CLI path; it never leaves `USER` or example paths in the installed plist.

`uninstall_app.sh` performs tolerant bootout and removes only its app and plist.

- [x] **Step 6: Run tests and inspect the bundle**

Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
swift test
./scripts/build_app.sh
codesign --verify --deep --strict dist/RebornQuota.app
plutil -lint dist/RebornQuota.app/Contents/Info.plist
plutil -lint dist/com.maoxian.reborn-quota.plist
plutil -extract CFBundleIdentifier raw dist/RebornQuota.app/Contents/Info.plist | grep -Fx com.maoxian.reborn-quota
plutil -extract CFBundleExecutable raw dist/RebornQuota.app/Contents/Info.plist | grep -Fx RebornQuotaCompanion
plutil -extract CFBundlePackageType raw dist/RebornQuota.app/Contents/Info.plist | grep -Fx APPL
plutil -extract LSUIElement raw dist/RebornQuota.app/Contents/Info.plist | grep -Fx true
dist/RebornQuota.app/Contents/MacOS/RebornQuotaCompanion --smoke-exit
```

Expected: all pass; required bundle keys match exactly and `--smoke-exit` returns 0 without leaving a process.

- [x] **Step 7: Record checkpoint**

Mark Task 8 complete. Do not install outside the workspace until explicit escalation is approved.

### Task 9: End-to-end QA and installation

**Files:**
- Create: `companion/qa/final-verification.md`
- Create: `companion/qa/quota-compact.png`
- Create: `companion/qa/quota-expanded.png`
- Modify only after approval: `~/Applications/RebornQuota.app`
- Modify only after approval: `~/Library/LaunchAgents/com.maoxian.reborn-quota.plist`

- [x] **Step 1: Run fresh automated verification**

Run:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion
swift test
./scripts/build_app.sh
codesign --verify --deep --strict dist/RebornQuota.app
plutil -lint dist/RebornQuota.app/Contents/Info.plist
```

Expected: zero failures.

- [x] **Step 2: Resolve uninstalled end-to-end QA** *(deferred by user request; no GUI launch or performance collection)*

Build the QA-only bundle first:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && QA_BUILD=1 ./scripts/build_app.sh
```

Before invoking the GUI with `open`, request scoped approval for that GUI launch. Then run:

```bash
open -na /Users/maoxian/Work/reborn-transformation-gun-run/companion/dist/RebornQuota.app --args \
  --qa-restart-child-after 3 \
  --qa-report /Users/maoxian/Work/reborn-transformation-gun-run/companion/qa/reconnect-report.json
```

While Codex and Reborn are visible, verify real normalized weekly data, compact/expanded UI, drag/resize following, ordinary/full-screen Space behavior, pet hide/show, no focus stealing, and Dock/Cmd-Tab absence. Ask the user to quit/reopen Codex for the host-restart observation; no QA command may kill Codex. Confirm `qa/reconnect-report.json` shows that only the owned App Server child was restarted and a new connection epoch became available. Quit with `pkill -x RebornQuotaCompanion` and confirm `pgrep -x RebornQuotaCompanion` returns no process.

- [x] **Step 3: Record evidence status** *(automated evidence recorded; screenshots and live performance remain explicitly deferred)*

Save compact/expanded screenshots and write measured follow latency, idle/moving CPU, detected pet discriminator, Codex CLI version, app bundle version, test counts, and known limitations to `companion/qa/final-verification.md`.

- [x] **Step 4: Request approval for per-user installation**

Rebuild the production bundle without QA controls:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && ./scripts/build_app.sh
```

The installation writes outside `/Users/maoxian/Work`. Request scoped escalation for `companion/scripts/install_app.sh`; do not modify `ChatGPT.app` or any pet package.

- [x] **Step 5: Install and verify launchd state**

Run after approval:

```bash
cd /Users/maoxian/Work/reborn-transformation-gun-run/companion && ./scripts/install_app.sh
launchctl print "gui/$(id -u)/com.maoxian.reborn-quota"
codesign --verify --deep --strict ~/Applications/RebornQuota.app
plutil -lint ~/Library/LaunchAgents/com.maoxian.reborn-quota.plist
```

Expected: LaunchAgent running, one companion instance, bubble attached to Reborn, valid ad-hoc signature.

- [x] **Step 6: Final regression check** *(hashes and single LaunchAgent PID verified; interactive Codex restart walk-through deferred by user request)*

Run `shasum -a 256 -c /Users/maoxian/Work/reborn-transformation-gun-run/qa/reborn-quota-companion-baseline.sha256` and require all four installed/packaged Reborn files to report `OK`. Quit/reopen Codex and confirm the companion reconnects without duplicate processes or repeated permission prompts.

- [x] **Step 7: Record final result**

Complete `companion/qa/final-verification.md` with installation paths and uninstall command.
