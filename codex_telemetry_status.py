#!/usr/bin/env python3
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DB = Path.home() / 'Library' / 'Application Support' / 'CodexSpeedMonitor' / 'codex_telemetry.sqlite'
DB = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(os.environ.get('CODEX_TELEMETRY_DB', DEFAULT_DB))
if not DB.exists():
    print(json.dumps({'ok': False, 'db': str(DB), 'error': 'database not found; run scripts/install.sh and use Codex once'}))
    raise SystemExit(1)
conn = sqlite3.connect(DB)
conn.row_factory = sqlite3.Row
cutover_row = conn.execute("select value from capture_state where key='trusted_cutover_at'").fetchone()
cutover = cutover_row['value'] if cutover_row else '1970-01-01T00:00:00Z'
heartbeat = conn.execute("select ts,pid,uptime_seconds,otlp_requests,app_response_events,turn_observations,best_turns from daemon_heartbeats order by id desc limit 1").fetchone()
last_turn = conn.execute("select completed_at,model,mode,total_tokens,output_tokens_per_second from codex_turns where completed_at >= ? and completed_at is not null order by completed_at desc limit 1", (cutover,)).fetchone()
counts = conn.execute("select (select count(*) from otlp_requests) otlp_requests, (select count(*) from app_response_events) app_events, (select count(*) from turn_observations) observations, (select count(*) from codex_turns) all_turns, (select count(*) from codex_turns where completed_at >= ?) trusted_turns", (cutover,)).fetchone()
status = {'db': str(DB), 'trusted_cutover_at': cutover, 'counts': dict(counts)}
if heartbeat:
    status['heartbeat'] = dict(heartbeat)
    try:
        dt = datetime.fromisoformat(heartbeat['ts'])
        status['heartbeat_age_seconds'] = round((datetime.now(timezone.utc) - dt).total_seconds(), 1)
    except Exception:
        pass
if last_turn:
    status['last_trusted_turn'] = dict(last_turn)
print(json.dumps(status, indent=2))
