#!/usr/bin/env bash
set -uo pipefail

LABEL="${CODEX_TELEMETRY_LABEL:-dev.codexspeedmonitor.daemon}"
DATA_DIR="${CODEX_TELEMETRY_HOME:-${HOME}/Library/Application Support/CodexSpeedMonitor}"
DB_PATH="${CODEX_TELEMETRY_DB:-${DATA_DIR}/codex_telemetry.sqlite}"
CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"

failures=0

check() {
  local label="$1"
  shift
  if "$@" >/tmp/codex-speed-monitor-doctor.out 2>/tmp/codex-speed-monitor-doctor.err; then
    printf "PASS %s\n" "$label"
  else
    failures=$((failures + 1))
    printf "FAIL %s\n" "$label"
    sed -n '1,3p' /tmp/codex-speed-monitor-doctor.err
  fi
}

check "python3 is available" command -v python3
check "xcrun is available" command -v xcrun
check "Codex home exists" test -d "$CODEX_HOME"
check "Codex log database exists" test -f "$CODEX_HOME/logs_2.sqlite"
check "Codex state database exists" test -f "$CODEX_HOME/state_5.sqlite"

if launchctl print "gui/$(id -u)/${LABEL}" >/tmp/codex-speed-monitor-doctor.out 2>/tmp/codex-speed-monitor-doctor.err; then
  printf "PASS LaunchAgent is loaded\n"
else
  failures=$((failures + 1))
  printf "FAIL LaunchAgent is loaded\n"
fi

if curl -fsS http://127.0.0.1:4318/health >/tmp/codex-speed-monitor-doctor.out 2>/tmp/codex-speed-monitor-doctor.err; then
  printf "PASS local collector is healthy\n"
else
  failures=$((failures + 1))
  printf "FAIL local collector is healthy\n"
fi

if [[ -f "$DB_PATH" ]]; then
  printf "PASS telemetry database exists\n"
else
  failures=$((failures + 1))
  printf "FAIL telemetry database exists: %s\n" "$DB_PATH"
fi

if [[ "$failures" -eq 0 ]]; then
  printf "\nCodex Speed Monitor looks healthy.\n"
else
  printf "\n%d check(s) failed. If this is a fresh install, open Codex, send one message, then run this again.\n" "$failures"
fi

exit "$failures"
