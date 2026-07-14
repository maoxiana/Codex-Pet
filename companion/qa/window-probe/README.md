# Reborn window-probe feasibility gate

Status: **IDENTIFICATION PASSED; PERFORMANCE EXPLICITLY DEFERRED AND UNVERIFIED.** The current schema-version-2 `ax-tree.json` is time-aligned with `pet-visible.json`. The current `discriminator.json` requires AX and identifies layer 3. The current explicitly deferred `gate-result.json` records `identificationPassed: true`, `passed: true`, `performanceVerified: false`, and `performanceDeferred: true`. This deferred pass permits development to continue; it is not a strict performance pass. No latency or CPU metrics have been measured.

## Safety boundary

The probe reads `CGWindowListCopyWindowInfo` metadata only. It never captures pixels and never requests Screen Recording. It resolves each owner PID with `NSRunningApplication(processIdentifier:)` and retains only processes whose bundle identifier is `com.openai.codex`. Title, alpha, and sharing state are never required. For the current discriminator, on-screen state is fail-closed: only `isOnScreen: true` is positive visibility evidence, while `false` or a missing value does not match. The harness does not patch or re-sign ChatGPT.app and does not modify installed or packaged Reborn pet files.

Accessibility is an explicit fallback. `ax-snapshot` records only roles, subroles, identifiers, geometry, tree relationships, and notification-registration result codes; it never records AX title, value, or description text. The command is non-prompting by default. Only an explicit `--prompt` flag calls `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt=true`, before traversal; without that flag the probe only calls `AXIsProcessTrusted()`.

The current `ax-tree.json` reports `trustedForAccessibility: true`, successful notification registration for both direct windows, and a complete 356×320 control-free pet subtree at the same bounds as the visible CG candidate. The large main subtree reaches the cap, but its shallow `AXCloseButton`, `AXMinimizeButton`, and `AXFullScreenButton` descendants are captured first and reject it immediately. Schema-version-2 captures record role, subrole, children-read, and subtree-completeness state; any failed read, mismatch, truncation, or cap exhaustion fails closed whenever absence would otherwise be inferred.

## Real smoke evidence

`unclassified-smoke.json` was written by the release probe on 2026-07-13. It proves the unprotected metadata path is operational outside the build sandbox:

- CG owner name: `ChatGPT`
- owner PID in this run: `7981` (ephemeral; do not encode it in a rule)
- resolved bundle identifier: `com.openai.codex`
- retained Codex window records: 13
- displays: two Retina displays, CG display IDs 1 and 3, each with a backing scale factor of 2
- observed layers: 0, 3, and 25

This capture is intentionally named `unclassified-smoke`. It is not labeled pet-visible, pet-hidden, or any other acceptance state, so no pet layer or discriminator is claimed from it.

The Codex desktop app cannot be controlled through the available Computer Use channel (the runtime rejects `com.openai.codex` as a protected target). The named CG states were therefore staged by a person/controller while the release probe was invoked; future recaptures require the same manual verification.

## Captured state commands

These commands produced the existing evidence. The user explicitly deferred additional interactive capture; do not rerun them unless that decision changes:

```sh
.build/release/RebornWindowProbe snapshot --state pet-hidden --output qa/window-probe/pet-hidden.json
.build/release/RebornWindowProbe snapshot --state pet-visible --output qa/window-probe/pet-visible.json
.build/release/RebornWindowProbe snapshot --state pet-moved --output qa/window-probe/pet-moved.json
.build/release/RebornWindowProbe snapshot --state pet-resized --output qa/window-probe/pet-resized.json
.build/release/RebornWindowProbe snapshot --state notification-open --output qa/window-probe/notification-open.json
.build/release/RebornWindowProbe snapshot --state small-codex-window --output qa/window-probe/small-codex-window.json
.build/release/RebornWindowProbe snapshot --state ordinary-space-switch --output qa/window-probe/ordinary-space-switch.json
.build/release/RebornWindowProbe snapshot --state fullscreen-space --output qa/window-probe/fullscreen-space.json
.build/release/RebornWindowProbe snapshot --state secondary-display --output qa/window-probe/secondary-display.json
```

A second display was present during the smoke run, so `secondary-display.json` remains required for this machine. The coordinate suite separately covers left, above, below, mixed-visible-frame, and Retina layouts without multiplying logical window bounds by scale.

The current rule was derived after the hidden, visible, and small-window states were verified. The following command reproduces it. `notification-open.json` contains the visible pet; it is required observational behavior evidence and must never be supplied as a negative `--exclude` fixture:

```sh
.build/release/RebornWindowProbe derive \
  --hidden qa/window-probe/pet-hidden.json \
  --visible qa/window-probe/pet-visible.json \
  --exclude qa/window-probe/small-codex-window.json \
  --ax-tree qa/window-probe/ax-tree.json \
  --output qa/window-probe/discriminator.json
```

`--ax-tree` explicitly requests AX-assisted derivation and persists the structural requirement even when CG metadata could now separate the visible state. Omit it only when a CG-only rule is intentionally desired. AX-assisted derivation requires a trusted AX document, applies the persisted no-standard-control-buttons predicate, and correlates the unique AX window to exactly one visible CG window by PID and geometry. With `requireOnScreen: true`, only `isOnScreen: true` is positive evidence; `false` and a missing value both fail closed. This preserves the hidden/small captures, where the window object remains but positive on-screen evidence disappears. The resulting `discriminator.json` records `requiresAX: true`, the exact predicate, source evidence, observed PID/bounds, and successful notifications. A passive check never opens a system prompt:

```sh
.build/release/RebornWindowProbe ax-snapshot --output qa/window-probe/ax-tree.json
```

If the passive result says `trustedForAccessibility: false`, a person present at the Mac may explicitly request the macOS accessibility-permission UI:

```sh
.build/release/RebornWindowProbe ax-snapshot --prompt --output qa/window-probe/ax-tree.json
```

The first prompted invocation may still write `trustedForAccessibility: false` while macOS presents or processes the permission request. After the person grants access, run the snapshot again and require `trustedForAccessibility: true` plus a non-empty sanitized tree before treating it as authorized evidence. The controller, not an unattended agent, performs this prompted run.

Do not adopt an AX-assisted discriminator unless the sanitized tree shows this stable, pet-specific geometry/tree relationship across the same states. Live tracking queries only the app's direct `kAXWindowsAttribute`. Each direct window is scanned breadth-first with a strict per-window descendant cap and exits immediately on a forbidden standard control, so unrelated application/menu trees and the main content hierarchy cannot exhaust pet selection.

The visible CG snapshot and AX tree must be time-aligned. Place the pet in the visible state, keep it stationary, and run these two commands immediately one after the other:

```sh
.build/release/RebornWindowProbe snapshot --state pet-visible --output qa/window-probe/pet-visible.json
.build/release/RebornWindowProbe ax-snapshot --output qa/window-probe/ax-tree.json
```

Derivation accepts only the Codex PID, observed layer 3, and full origin plus size within a two-logical-point tolerance. It normalizes both AX and CG bounds through the screen geometry recorded in `pet-visible.json`; there is no PID-plus-size fallback. A same-size window at a different origin or any wrong-layer window is rejected.

## Deferred performance measurements

The following measurements remain useful for a later performance-verification pass, but the user explicitly asked to stop collecting scenarios and continue implementation. No command in this section was run to manufacture metrics:

```sh
.build/release/RebornWindowProbe track --scenario dragging --duration-seconds 30 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/metrics/dragging.json
.build/release/RebornWindowProbe track --scenario covered --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/metrics/covered.json
.build/release/RebornWindowProbe track --scenario pet-hidden --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/metrics/pet-hidden.json
.build/release/RebornWindowProbe track --scenario ordinary-space-switch --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/metrics/ordinary-space-switch.json
.build/release/RebornWindowProbe track --scenario fullscreen-space --duration-seconds 15 --panel --discriminator qa/window-probe/discriminator.json --metrics-out qa/window-probe/metrics/fullscreen-space.json
```

The nonactivating 14-point colored panel is configured with `canJoinAllSpaces`, `fullScreenAuxiliary`, and `ignoresCycle`, is assigned candidate layer + 1, and follows converted AppKit coordinates. The harness validates actual CG ordering of the panel above the candidate. For AX-required rules, volatile CG order is not a runtime prefilter: bundle ID, layer, and the evidence-derived geometry envelope feed the required AX structural plus PID/bounds correlation. CG-only rules retain strict ordering. It consumes `AXMoved`/`AXResized` notifications when live registration succeeds and retains the 10 Hz idle / 60 Hz moving polling fallback. `maxFollowLatencyMs` begins at the AX event timestamp when available, otherwise at the poll tick before CG/AX capture and resolution, and ends only after the panel frame update is committed. `maxPanelUpdateMs` separately records the panel-mutation portion.

Acceptance thresholds are maximum movement detection latency ≤ 100 ms, maximum follow latency ≤ 34 ms, idle CPU < 1%, moving CPU < 5%, stable candidate behavior, panel above the pet, and no panel residue where the pet is absent. The metrics are maximum values, not percentiles. Strict evaluation also requires schema-version-1 metrics, `panelEnabled: true` for every required scenario including hidden, at least 30 seconds for dragging and 15 seconds for every other scenario, credible sample cadence and internally consistent timing/count fields, plus scenario, AX mode, and layer provenance matching the discriminator.

Default evaluation remains strict and fails while metrics are absent. Evaluation always writes the requested gate JSON first; a failed gate then exits with status 3, while a passed strict or explicitly deferred gate exits 0:

```sh
.build/release/RebornWindowProbe evaluate \
  --snapshots-dir qa/window-probe \
  --metrics-dir qa/window-probe/metrics \
  --output qa/window-probe/gate-result.json
```

To record the user's explicit decision to continue development without more scenario collection, use:

```sh
.build/release/RebornWindowProbe evaluate \
  --snapshots-dir qa/window-probe \
  --metrics-dir qa/window-probe/metrics \
  --defer-performance \
  --deferral-note "User explicitly deferred additional scenario collection to continue implementation" \
  --output qa/window-probe/gate-result.json
```

The result separately records `identificationPassed`, `performanceVerified`, `performanceDeferred`, and `deferralNote`; absent metric values remain JSON `null`, and missing metrics become warnings only in explicit deferral mode. Missing or invalid identity snapshots, the discriminator, trusted complete AX evidence, or exact structural correlation always remain failures. All eight named structural snapshots are required: hidden, visible, moved, resized, notification-open, small-window, ordinary-Space, and fullscreen-Space. If any of that evidence records two screens, `secondary-display.json` is also required. Identity validation requires one candidate in visible/moved/resized, zero under the strict CG evidence rule in hidden/small-window, and one on the required secondary display. Notification-open and ordinary/fullscreen Space snapshots must exist but are recorded as behavior evidence with observed candidate counts rather than forced to zero or one.
