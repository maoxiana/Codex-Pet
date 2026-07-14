# RebornQuota final verification

## Automated verification

- Current Swift tests: 234 passed, 0 failed.
- Production bundle: `dist/RebornQuota.app`.
- Bundle identifier: `com.maoxian.reborn-quota`.
- Bundle version: `0.1.0` (`CFBundleVersion` 1).
- App type: `LSUIElement`, no normal Dock application UI.
- Signature: valid ad-hoc signature (`codesign --verify --deep --strict`).
- App and LaunchAgent plists: valid.
- Production executable: QA-only restart/report controls absent.
- `--smoke-exit`: exited successfully without starting the application runtime.
- Both packaged `gate-result.json` resources byte-match the authoritative QA gate.
- Reborn installed/package baseline: all four hashes unchanged.
- Task 8 independent final review: no Critical, Important, or Minor findings.

## Runtime evidence intentionally deferred

At the user's request, the uninstalled GUI walk-through, screenshots, follow-latency sampling,
and idle/moving CPU collection were not repeated. The gate therefore remains explicit:

- `performanceDeferred: true`
- `performanceVerified: false`

No performance claim is made. Compact/expanded screenshot artifacts are intentionally absent.

## Position-follow hotfix

The first installed build could lag behind an automatically moving Reborn because a successful
AX notification registration reduced verification polling to 1 Hz even when individual move
notifications were missed. The locator now keeps a 10 Hz verification cadence and temporarily
uses 60 Hz while bounds are changing, returning to 10 Hz after 300 ms stable.

- Regression test: AX-active missed-move cadence passes.
- Full suite after the fix: 237 passed, 0 failed.
- Updated production bundle: built, signed, installed, and LaunchAgent restarted.
- Reborn pet/package baseline: unchanged.
- Performance remains deferred and unverified after the cadence change.
- The updated ad-hoc executable may require Accessibility permission to be re-enabled before
  the bubble is visible again.
- The stale Accessibility entry was removed and the currently installed app was re-added.
- Final same-frame window check after permission recovery: horizontal center delta `0pt`,
  vertical pet-to-bubble gap `8pt`.

## Visual-anchor hotfix

The same-frame check above proved that the panel was centered over Codex's outer 356×320 pet
window, but that window also contains transient status UI and transparent layout space. It is
not the visual Reborn bounds. The runtime resolver now anchors to the unique nested
`AXApplicationGroup`, which is the pet/card region and moves when the thinking layout changes.

- Recorded AX fixture resolves the visual region at 154×167 instead of the 356×320 outer window.
- A regression fixture moves that region inside an unchanged outer window and verifies that the
  quota anchor follows it.
- Missing, ambiguous, untrusted, outside-window, and wrong-coordinate-space anchors are rejected;
  runtime retains the correlated outer-window fallback.
- Full suite after the visual-anchor fix: 241 passed, 0 failed.
- Updated production bundle: built, installed, signature/plist validation passed, and LaunchAgent
  is running. The current installed app was removed and re-added in Accessibility after the
  ad-hoc binary replacement invalidated the prior grant.
- Live post-authorization geometry: outer Codex pet window `(1381, -615, 356×320)` and quota
  panel `(1566, -476, 164×32)`. Compared with outer-window centering, the panel moved `89pt`
  right and `179pt` down, proving that the nested visual anchor is active.
- Reborn pet/package baseline: unchanged.
- Performance remains deferred and unverified.

## Persistent-display recovery

The Accessibility list could show RebornQuota as enabled while the process's persisted result was
still `denialRecorded: true`, and a readable permission could coexist with a temporarily unreadable
Codex AX subtree. Both cases previously hid the panel indefinitely.

- Reset only `Accessibility/com.maoxian.reborn-quota` with `tccutil`, then re-added the final
  installed binary while the service was stopped. The live process now records
  `denialRecorded: false`.
- Added a trusted, exact-CG fallback. It is enabled only when Accessibility is actually trusted and
  exactly one on-screen `com.openai.codex` layer-3 window matches the recorded `356×320` pet size.
- The fallback uses the live-measured Reborn card offset; false trust, wrong size, or multiple
  matching windows still fail closed.
- Current full suite: 234 passed, 0 failed.
- Live panel before restart: `(1575, -465, 200×56)`.
- Deliberate same-binary process restart retained `denialRecorded: false` and a visible panel at
  `(1599, -512, 200×56)` after the pet moved.
- Reborn pet/package baseline: unchanged.

## Installation

Status: installed and running as a per-user LaunchAgent.

Installed paths:

- `~/Applications/RebornQuota.app`
- `~/Library/LaunchAgents/com.maoxian.reborn-quota.plist`

Installed runtime verification:

- LaunchAgent `com.maoxian.reborn-quota`: `state = running`.
- Installed program: `/Users/maoxian/Applications/RebornQuota.app/Contents/MacOS/RebornQuotaCompanion`.
- Configured CLI: `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli 0.144.0-alpha.4`).
- `RunAtLoad = true`, `KeepAlive.SuccessfulExit = false`, `ThrottleInterval = 30`.
- Installed app signature and LaunchAgent plist are valid.
- Installed production binary contains no QA restart/report controls.
- Installed gate resources byte-match the authoritative gate.
- Post-install Reborn installed/package baseline: all four hashes unchanged.

The first install attempt stopped before copying because the installer used zsh's reserved
`status` name. The script was corrected to use non-special local names and the subsequent
installation completed successfully.

Uninstall command after installation:

```bash
/Users/maoxian/Work/reborn-transformation-gun-run/companion/scripts/uninstall_app.sh
```
