#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LABEL="com.maoxian.reborn-quota"
typeset -a TEMP_PATHS
TEMP_PATHS=()
cleanup_temporary_paths() {
  local temporary_path
  for temporary_path in "${TEMP_PATHS[@]}"; do
    /bin/rm -rf -- "$temporary_path"
  done
}
trap cleanup_temporary_paths EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$HOME" == /* ]] || {
  print -u2 "error: HOME must be absolute"
  exit 1
}

resolve_codex_cli() {
  local candidate
  if [[ -n "${CODEX_CLI_PATH:-}" ]]; then
    [[ "$CODEX_CLI_PATH" == /* ]] || {
      print -u2 "error: CODEX_CLI_PATH must be absolute"
      return 1
    }
    candidate="$CODEX_CLI_PATH"
  elif [[ -x "/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
    candidate="/Applications/ChatGPT.app/Contents/Resources/codex"
  elif [[ -x "$HOME/Applications/ChatGPT.app/Contents/Resources/codex" ]]; then
    candidate="$HOME/Applications/ChatGPT.app/Contents/Resources/codex"
  else
    print -u2 "error: Codex CLI was not found"
    return 1
  fi
  [[ -f "$candidate" && -x "$candidate" && "$candidate" == /* ]] || {
    print -u2 "error: Codex CLI is not an executable regular file"
    return 1
  }
  print -r -- "$candidate"
}

validate_codex_cli() {
  local executable="$1"
  local output_file
  output_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/reborn-quota-codex-version.XXXXXX")"
  TEMP_PATHS+=("$output_file")
  "$executable" --version >"$output_file" 2>&1 &
  local child=$!
  local completed=0
  for _ in {1..20}; do
    if ! /bin/kill -0 "$child" 2>/dev/null; then
      completed=1
      break
    fi
    /bin/sleep 0.1
  done
  if (( ! completed )); then
    /bin/kill -TERM "$child" 2>/dev/null || true
    /bin/sleep 0.1
    /bin/kill -KILL "$child" 2>/dev/null || true
  fi
  local wait_status=0
  wait "$child" || wait_status=$?
  (( completed && wait_status == 0 )) || {
    print -u2 "error: Codex CLI version probe failed or exceeded two seconds"
    return 1
  }
}

CODEX_CLI="$(resolve_codex_cli)"
validate_codex_cli "$CODEX_CLI"

CODEX_CLI_PATH="$CODEX_CLI" QA_BUILD=0 "$ROOT_DIR/scripts/build_app.sh" >/dev/null

SOURCE_APP="$ROOT_DIR/dist/RebornQuota.app"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
APP_DESTINATION="$HOME/Applications/RebornQuota.app"
LAUNCH_DIRECTORY="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_DIRECTORY/$LABEL.plist"
TEMPLATE="$ROOT_DIR/Resources/$LABEL.plist.template"
DOMAIN="gui/$(/usr/bin/id -u)"

[[ "$APP_DESTINATION" == /* && "$LAUNCH_PLIST" == /* ]] || {
  print -u2 "error: installation paths must be absolute"
  exit 1
}

/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/mkdir -p "$HOME/Applications" "$LAUNCH_DIRECTORY"

APP_STAGING="$(/usr/bin/mktemp -d "$HOME/Applications/.RebornQuota.app.installing.XXXXXX")"
PLIST_STAGING="$(/usr/bin/mktemp "$LAUNCH_DIRECTORY/.$LABEL.plist.installing.XXXXXX")"
TEMP_PATHS+=("$APP_STAGING" "$PLIST_STAGING")
/usr/bin/ditto "$SOURCE_APP" "$APP_STAGING"
/bin/rm -rf "$APP_DESTINATION"
/bin/mv "$APP_STAGING" "$APP_DESTINATION"

/bin/cp "$TEMPLATE" "$PLIST_STAGING"
/usr/bin/plutil -remove ProgramArguments.0 "$PLIST_STAGING"
/usr/bin/plutil -insert ProgramArguments.0 -string \
  "$APP_DESTINATION/Contents/MacOS/RebornQuotaCompanion" "$PLIST_STAGING"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_CLI_PATH -string \
  "$CODEX_CLI" "$PLIST_STAGING"
if /usr/bin/grep -Eq '__APP_EXECUTABLE__|__CODEX_CLI_PATH__|/Users/USER/' "$PLIST_STAGING"; then
  print -u2 "error: installed LaunchAgent contains an unresolved placeholder"
  exit 1
fi
/usr/bin/plutil -lint "$PLIST_STAGING" >/dev/null
/bin/mv "$PLIST_STAGING" "$LAUNCH_PLIST"

/bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_PLIST"
/bin/launchctl kickstart -k "$DOMAIN/$LABEL"
print "Installed $APP_DESTINATION"
