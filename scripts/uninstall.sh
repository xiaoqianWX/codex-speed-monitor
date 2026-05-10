#!/usr/bin/env bash
set -euo pipefail

LABEL="${CODEX_TELEMETRY_LABEL:-dev.codexspeedmonitor.daemon}"
DATA_DIR="${CODEX_TELEMETRY_HOME:-${HOME}/Library/Application Support/CodexSpeedMonitor}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP_TARGET="${CODEX_TELEMETRY_APP_TARGET:-${HOME}/Applications/CodexSpeedMonitor.app}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge)
      PURGE=1
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
while IFS= read -r pid; do
  kill -TERM "$pid" >/dev/null 2>&1 || true
done < <(pgrep -f "${APP_TARGET}/Contents/MacOS/CodexSpeedMonitor" || true)
rm -f "${PLIST_PATH}"
rm -rf "${APP_TARGET}"

CONFIG_PATH="${CODEX_HOME}/config.toml"
if [[ -f "${CONFIG_PATH}" ]] && grep -q '# >>> codex-speed-monitor' "${CONFIG_PATH}"; then
  cp "${CONFIG_PATH}" "${CONFIG_PATH}.codex-speed-monitor-uninstall-backup.$(date +%Y%m%d%H%M%S)"
  awk '
    /# >>> codex-speed-monitor/ {skip=1; next}
    /# <<< codex-speed-monitor/ {skip=0; next}
    skip != 1 {print}
  ' "${CONFIG_PATH}" > "${CONFIG_PATH}.tmp"
  mv "${CONFIG_PATH}.tmp" "${CONFIG_PATH}"
fi

if [[ "${PURGE}" -eq 1 ]]; then
  rm -rf "${DATA_DIR}"
  CONFIG_JSON="${HOME}/Library/Application Support/CodexSpeedMonitor/config.json"
  if [[ -f "${CONFIG_JSON}" ]]; then
    CONFIG_DATA_DIR="$(python3 - "$CONFIG_JSON" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1])).get("data_dir", ""))
except Exception:
    print("")
PY
)"
    if [[ "${CONFIG_DATA_DIR}" == "${DATA_DIR}" ]]; then
      rm -f "${CONFIG_JSON}"
    fi
  fi
else
  rm -rf "${DATA_DIR}/bin"
fi

echo "Uninstalled ${LABEL}"
if [[ "${PURGE}" -eq 0 ]]; then
  echo "Kept data in ${DATA_DIR}. Re-run with --purge to remove the database and logs."
fi
