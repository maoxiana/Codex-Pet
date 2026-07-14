#!/bin/zsh
set -euo pipefail

LABEL="com.maoxian.reborn-quota"
[[ "$HOME" == /* ]] || {
  print -u2 "error: HOME must be absolute"
  exit 1
}
DOMAIN="gui/$(/usr/bin/id -u)"
APP_PATH="$HOME/Applications/RebornQuota.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/rm -rf "$APP_PATH"
/bin/rm -f "$PLIST_PATH"
print "Removed RebornQuota app and LaunchAgent"
