#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${CODEX_TELEMETRY_LABEL:-dev.codexspeedmonitor.daemon}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
DATA_DIR="${CODEX_TELEMETRY_HOME:-${HOME}/Library/Application Support/CodexSpeedMonitor}"
BIN_DIR="${DATA_DIR}/bin"
LOG_DIR="${DATA_DIR}/logs"
DB_PATH="${CODEX_TELEMETRY_DB:-${DATA_DIR}/codex_telemetry.sqlite}"
LOG_DB="${CODEX_TELEMETRY_LOG_DB:-${CODEX_HOME}/logs_2.sqlite}"
STATE_DB="${CODEX_TELEMETRY_STATE_DB:-${CODEX_HOME}/state_5.sqlite}"
INTERVAL="${CODEX_TELEMETRY_INTERVAL:-15}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP_TARGET="${CODEX_TELEMETRY_APP_TARGET:-${HOME}/Applications/CodexSpeedMonitor.app}"
INSTALL_APP=1
CONFIGURE_CODEX=1

stop_viewer_app() {
  local app_binary="${APP_TARGET}/Contents/MacOS/CodexSpeedMonitor"

  /usr/bin/osascript -e 'tell application id "dev.codexspeedmonitor.viewer" to quit' >/dev/null 2>&1 || true

  if pgrep -f "${app_binary}" >/dev/null 2>&1; then
    pkill -TERM -f "${app_binary}" >/dev/null 2>&1 || true
    sleep 1
  fi

  if pgrep -f "${app_binary}" >/dev/null 2>&1; then
    pkill -KILL -f "${app_binary}" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-app)
      INSTALL_APP=0
      ;;
    --skip-codex-config)
      CONFIGURE_CODEX=0
      ;;
    --data-dir)
      DATA_DIR="$2"
      BIN_DIR="${DATA_DIR}/bin"
      LOG_DIR="${DATA_DIR}/logs"
      DB_PATH="${CODEX_TELEMETRY_DB:-${DATA_DIR}/codex_telemetry.sqlite}"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

mkdir -p "${BIN_DIR}" "${LOG_DIR}" "$(dirname "${PLIST_PATH}")"
cp "${ROOT}/codex_telemetry_daemon.py" "${BIN_DIR}/"
cp "${ROOT}/codex_telemetry_status.py" "${BIN_DIR}/"
cp "${ROOT}/codex-tracked" "${BIN_DIR}/"
chmod +x "${BIN_DIR}/codex_telemetry_daemon.py" "${BIN_DIR}/codex_telemetry_status.py" "${BIN_DIR}/codex-tracked"

DEFAULT_CONFIG_DIR="${HOME}/Library/Application Support/CodexSpeedMonitor"
mkdir -p "${DEFAULT_CONFIG_DIR}"
if [[ -f "${DEFAULT_CONFIG_DIR}/config.json" ]]; then
  cp "${DEFAULT_CONFIG_DIR}/config.json" "${DEFAULT_CONFIG_DIR}/config.json.backup.$(date +%Y%m%d%H%M%S)"
fi
python3 - "$DEFAULT_CONFIG_DIR/config.json" "$DB_PATH" "$DATA_DIR" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "db_path": sys.argv[2],
    "data_dir": sys.argv[3],
}
path.write_text(json.dumps(payload, indent=2) + "\n")
PY

cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${BIN_DIR}/codex_telemetry_daemon.py</string>
    <string>--db</string>
    <string>${DB_PATH}</string>
    <string>--log-db</string>
    <string>${LOG_DB}</string>
    <string>--state-db</string>
    <string>${STATE_DB}</string>
    <string>--interval</string>
    <string>${INTERVAL}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_HOME</key>
    <string>${CODEX_HOME}</string>
    <key>CODEX_TELEMETRY_DB</key>
    <string>${DB_PATH}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/daemon.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/daemon.err.log</string>
  <key>WorkingDirectory</key>
  <string>${DATA_DIR}</string>
</dict>
</plist>
PLIST

if [[ "${CONFIGURE_CODEX}" -eq 1 ]]; then
  mkdir -p "${CODEX_HOME}"
  CONFIG_PATH="${CODEX_HOME}/config.toml"
  touch "${CONFIG_PATH}"
  if grep -q '^\[otel\]' "${CONFIG_PATH}" >/dev/null 2>&1; then
    echo "Codex config already has an [otel] block; leaving it unchanged."
  else
    cp "${CONFIG_PATH}" "${CONFIG_PATH}.codex-speed-monitor-backup.$(date +%Y%m%d%H%M%S)"
    cat >> "${CONFIG_PATH}" <<'TOML'

# >>> codex-speed-monitor
[otel]
environment = "local-codex-telemetry"
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "json" } }
trace_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/traces", protocol = "json" } }
metrics_exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/metrics", protocol = "json" } }
# <<< codex-speed-monitor
TOML
  fi
fi

launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

if [[ "${INSTALL_APP}" -eq 1 ]]; then
  if "${ROOT}/scripts/build_app.sh" >/tmp/codex-speed-monitor-build-path.txt; then
    mkdir -p "$(dirname "${APP_TARGET}")"
    stop_viewer_app
    rm -rf "${APP_TARGET}"
    cp -R "$(cat /tmp/codex-speed-monitor-build-path.txt)" "${APP_TARGET}"
    open "${APP_TARGET}" || true
  else
    echo "Viewer build failed; daemon is installed. Run scripts/build_app.sh after installing Xcode Command Line Tools." >&2
  fi
fi

echo "Installed ${LABEL}"
echo "Database: ${DB_PATH}"
echo "Health:   http://127.0.0.1:4318/health"
echo "Status:   ${BIN_DIR}/codex_telemetry_status.py"
