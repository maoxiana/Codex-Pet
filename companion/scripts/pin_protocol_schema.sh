#!/bin/bash
set -euo pipefail

readonly EXPECTED_VERSION="codex-cli 0.144.0-alpha.4"
readonly PIN_DIRECTORY="0.144.0-alpha.4"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/codex" >&2
  exit 64
fi

readonly CODEX_EXECUTABLE="$1"
if [[ "$CODEX_EXECUTABLE" != /* ]] || [[ ! -f "$CODEX_EXECUTABLE" ]] || [[ ! -x "$CODEX_EXECUTABLE" ]]; then
  echo "codex executable must be an absolute executable regular file" >&2
  exit 65
fi

actual_version="$("$CODEX_EXECUTABLE" --version)"
if [[ "$actual_version" != "$EXPECTED_VERSION" ]]; then
  echo "expected $EXPECTED_VERSION" >&2
  exit 66
fi

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly COMPANION_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
readonly DESTINATION="$COMPANION_DIRECTORY/ProtocolSchemas/$PIN_DIRECTORY"
readonly DESTINATION_PARENT="$(dirname "$DESTINATION")"
readonly GENERATED_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/reborn-schema-generated.XXXXXX")"
mkdir -p "$DESTINATION_PARENT"
readonly STAGING_DIRECTORY="$(mktemp -d "$DESTINATION_PARENT/.reborn-schema-pinned.XXXXXX")"
readonly BACKUP_DIRECTORY="$(mktemp -d "$DESTINATION_PARENT/.reborn-schema-backup.XXXXXX")"
rmdir "$BACKUP_DIRECTORY"
backup_active=0
swap_committed=0

cleanup() {
  local command_status=$?
  trap - EXIT INT TERM HUP
  if [[ -e "$BACKUP_DIRECTORY" ]]; then
    if [[ ! -e "$DESTINATION" ]]; then
      mv "$BACKUP_DIRECTORY" "$DESTINATION" || true
    else
      rm -rf "$BACKUP_DIRECTORY"
    fi
  fi
  rm -rf "$GENERATED_DIRECTORY" "$STAGING_DIRECTORY"
  if [[ $swap_committed -eq 1 ]]; then
    rm -rf "$BACKUP_DIRECTORY"
  fi
  exit "$command_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

"$CODEX_EXECUTABLE" app-server generate-json-schema \
  --experimental \
  --out "$GENERATED_DIRECTORY"

files=(
  "JSONRPCMessage.json"
  "JSONRPCResponse.json"
  "JSONRPCError.json"
  "JSONRPCErrorError.json"
  "RequestId.json"
  "ClientRequest.json"
  "ClientNotification.json"
  "ServerNotification.json"
  "v1/InitializeParams.json"
  "v1/InitializeResponse.json"
  "v2/GetAccountRateLimitsResponse.json"
  "v2/AccountRateLimitsUpdatedNotification.json"
)

for relative_path in "${files[@]}"; do
  source_path="$GENERATED_DIRECTORY/$relative_path"
  if [[ ! -f "$source_path" ]]; then
    echo "generated schema missing required file: $relative_path" >&2
    exit 67
  fi
  mkdir -p "$STAGING_DIRECTORY/$(dirname "$relative_path")"
  cp "$source_path" "$STAGING_DIRECTORY/$relative_path"
done

(
  cd "$STAGING_DIRECTORY"
  readonly staging_checksums=".SHA256SUMS.staging"
  for relative_path in "${files[@]}"; do
    shasum -a 256 "$relative_path"
  done > "$staging_checksums"
  shasum -a 256 -c "$staging_checksums"
  while read -r digest relative_path; do
    printf '%s  ProtocolSchemas/%s/%s\n' "$digest" "$PIN_DIRECTORY" "$relative_path"
  done < "$staging_checksums" > SHA256SUMS
  rm -f "$staging_checksums"
)

if [[ -e "$DESTINATION" ]]; then
  backup_active=1
  mv "$DESTINATION" "$BACKUP_DIRECTORY"
fi
mv "$STAGING_DIRECTORY" "$DESTINATION"
swap_committed=1
rm -rf "$BACKUP_DIRECTORY"
backup_active=0
