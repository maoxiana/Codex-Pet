#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/RebornQuota.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
LAUNCH_TEMPLATE="$ROOT_DIR/Resources/com.maoxian.reborn-quota.plist.template"
QA_GATE="$ROOT_DIR/qa/window-probe/gate-result.json"

[[ -f "$INFO_PLIST" && -f "$LAUNCH_TEMPLATE" && -f "$QA_GATE" ]] || {
  print -u2 "error: required bundle input is missing"
  exit 1
}

cd "$ROOT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-cache}"
/bin/mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"
build_arguments=(--disable-sandbox -c release)
if [[ "${QA_BUILD:-0}" == "1" ]]; then
  build_arguments+=(-Xswiftc -DREBORN_QUOTA_QA)
fi

/usr/bin/env swift build "${build_arguments[@]}"
BIN_PATH="$(/usr/bin/env swift build --disable-sandbox -c release --show-bin-path)"
EXECUTABLE="$BIN_PATH/RebornQuotaCompanion"
RESOURCE_BUNDLE="$BIN_PATH/RebornQuotaCompanion_RebornQuotaCompanion.bundle"
[[ -x "$EXECUTABLE" && -d "$RESOURCE_BUNDLE" ]] || {
  print -u2 "error: SwiftPM output is incomplete"
  exit 1
}

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/usr/bin/ditto "$EXECUTABLE" "$APP_DIR/Contents/MacOS/RebornQuotaCompanion"
/bin/chmod 0755 "$APP_DIR/Contents/MacOS/RebornQuotaCompanion"
/bin/cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"

# Preserve the complete SwiftPM resource bundle inside the signed app, and put
# the authoritative gate beside it for the app-bundle lookup path.
RESOURCE_DESTINATION="$APP_DIR/Contents/Resources/${RESOURCE_BUNDLE:t}"
/usr/bin/ditto "$RESOURCE_BUNDLE" "$RESOURCE_DESTINATION"
/bin/cp "$QA_GATE" "$RESOURCE_DESTINATION/gate-result.json"
/bin/cp "$QA_GATE" "$APP_DIR/Contents/Resources/gate-result.json"

if [[ -n "${CODEX_CLI_PATH:-}" ]]; then
  STAGING_CODEX_CLI="$CODEX_CLI_PATH"
elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
  STAGING_CODEX_CLI="/Applications/ChatGPT.app/Contents/Resources/codex"
elif [[ -x "$HOME/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
  STAGING_CODEX_CLI="$HOME/Applications/ChatGPT.app/Contents/Resources/codex"
else
  STAGING_CODEX_CLI="/Applications/ChatGPT.app/Contents/Resources/codex"
fi
[[ "$STAGING_CODEX_CLI" == /* && "$HOME" == /* ]] || {
  print -u2 "error: staging paths must be absolute"
  exit 1
}

STAGING_AGENT="$DIST_DIR/com.maoxian.reborn-quota.plist"
/bin/cp "$LAUNCH_TEMPLATE" "$STAGING_AGENT"
/usr/bin/plutil -remove ProgramArguments.0 "$STAGING_AGENT"
/usr/bin/plutil -insert ProgramArguments.0 -string \
  "$HOME/Applications/RebornQuota.app/Contents/MacOS/RebornQuotaCompanion" \
  "$STAGING_AGENT"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_CLI_PATH -string \
  "$STAGING_CODEX_CLI" "$STAGING_AGENT"
if /usr/bin/grep -Eq '__APP_EXECUTABLE__|__CODEX_CLI_PATH__|/Users/USER/' "$STAGING_AGENT"; then
  print -u2 "error: staging LaunchAgent contains an unresolved placeholder"
  exit 1
fi
/usr/bin/plutil -lint "$STAGING_AGENT" >/dev/null

/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_DIR"
print "$APP_DIR"
