#!/usr/bin/env python3
import argparse
import json
import os
import re
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
LOG_DB = CODEX_HOME / "logs_2.sqlite"
STATE_DB = CODEX_HOME / "state_5.sqlite"
SESSIONS = CODEX_HOME / "sessions"
ARCHIVED = CODEX_HOME / "archived_sessions"

RE_JSON_AFTER = [
    ("websocket_request", re.compile(r"websocket request: (\{.*\})")),
    ("websocket_event", re.compile(r"websocket event: (\{.*\})")),
    ("received_message", re.compile(r"Received message (\{.*\})")),
    ("response_create", re.compile(r"response\.create: (\{.*\})")),
]
SPAN_FIELD_RE = re.compile(r"([a-zA-Z0-9_.-]+)=([^\s}:]+)")

def q(conn, sql, params=()):
    conn.row_factory = sqlite3.Row
    return [dict(r) for r in conn.execute(sql, params)]

def get_thread(thread_id):
    if not STATE_DB.exists():
        return None
    conn = sqlite3.connect(STATE_DB)
    rows = q(conn, "select * from threads where id=?", (thread_id,))
    conn.close()
    return rows[0] if rows else None

def find_rollout(thread_id, state_row=None):
    if state_row and state_row.get("rollout_path") and Path(state_row["rollout_path"]).exists():
        return Path(state_row["rollout_path"])
    for root in (SESSIONS, ARCHIVED):
        if root.exists():
            matches = list(root.glob(f"**/*{thread_id}*.jsonl"))
            if matches:
                return matches[0]
    return None

def parse_rollout(path):
    out = {"path": str(path), "events": Counter(), "session_meta": None, "token_counts": [], "task_complete": [], "turn_contexts": []}
    if not path or not Path(path).exists():
        return out
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                ev = json.loads(line)
            except Exception:
                continue
            typ = ev.get("type")
            out["events"][typ] += 1
            payload = ev.get("payload") or {}
            if typ == "session_meta":
                out["session_meta"] = payload
            elif typ == "turn_context":
                out["turn_contexts"].append(payload)
            elif typ == "event_msg":
                ptyp = payload.get("type")
                out["events"][f"event_msg.{ptyp}"] += 1
                if ptyp == "token_count":
                    out["token_counts"].append(payload)
                elif ptyp == "task_complete":
                    out["task_complete"].append(payload)
    out["events"] = dict(out["events"])
    return out

def parse_log_body(body):
    parsed = {"span_fields": {}, "json_events": []}
    if not body:
        return parsed
    for k, v in SPAN_FIELD_RE.findall(body[:1200]):
        if k in ("thread.id", "turn.id", "model", "codex.turn.reasoning_effort", "otel.name", "service_tier"):
            parsed["span_fields"][k] = v.strip('"')
    for kind, rx in RE_JSON_AFTER:
        m = rx.search(body)
        if m:
            try:
                obj = json.loads(m.group(1))
                parsed["json_events"].append((kind, obj))
            except Exception:
                parsed["json_events"].append((kind, {"_parse_error": True, "prefix": m.group(1)[:300]}))
    return parsed

def analyze_logs(thread_id=None, marker=None, limit=200000):
    conn = sqlite3.connect(LOG_DB)
    clauses = []
    params = []
    if thread_id:
        clauses.append("thread_id=?")
        params.append(thread_id)
    if marker:
        clauses.append("feedback_log_body like ?")
        params.append(f"%{marker}%")
    where = " or ".join(f"({c})" for c in clauses) if clauses else "1=1"
    rows = q(conn, f"select id, ts, ts_nanos, level, target, thread_id, process_uuid, feedback_log_body from logs where {where} order by id desc limit ?", (*params, limit))
    conn.close()
    rows = list(reversed(rows))
    counts = Counter()
    event_types = Counter()
    response_ids = set()
    completed = []
    requests = []
    span_fields = defaultdict(Counter)
    examples = []
    for r in rows:
        body = r.get("feedback_log_body") or ""
        if "websocket request:" in body: counts["websocket_request_rows"] += 1
        if "websocket event:" in body: counts["websocket_event_rows"] += 1
        if "Received message" in body: counts["received_message_rows"] += 1
        if "response.completed" in body: counts["response_completed_mentions"] += 1
        if "service_tier" in body: counts["service_tier_mentions"] += 1
        if "token_count" in body: counts["token_count_mentions"] += 1
        parsed = parse_log_body(body)
        for k, v in parsed["span_fields"].items():
            span_fields[k][v] += 1
        for kind, obj in parsed["json_events"]:
            typ = obj.get("type")
            if typ:
                event_types[typ] += 1
            rid = obj.get("id") or (obj.get("response") or {}).get("id")
            if rid:
                response_ids.add(rid)
            if kind == "websocket_request":
                requests.append({"row_id": r["id"], "ts": r["ts"], "type": obj.get("type"), "model": obj.get("model"), "service_tier": obj.get("service_tier"), "reasoning": obj.get("reasoning"), "prompt_cache_key": obj.get("prompt_cache_key"), "previous_response_id": obj.get("previous_response_id")})
            if typ == "response.completed":
                usage = obj.get("response", obj).get("usage")
                resp = obj.get("response", obj)
                completed.append({"row_id": r["id"], "ts": r["ts"], "id": resp.get("id"), "model": resp.get("model"), "service_tier": resp.get("service_tier"), "created_at": resp.get("created_at"), "completed_at": resp.get("completed_at"), "usage": usage})
        if len(examples) < 8 and any(s in body for s in ["websocket request:", "response.completed", "service_tier requested=", "token_count", "turn.id="]):
            examples.append({"id": r["id"], "ts": r["ts"], "thread_id": r["thread_id"], "body": body[:700]})
    return {
        "row_count": len(rows),
        "counts": dict(counts),
        "event_types": dict(event_types),
        "response_id_count": len(response_ids),
        "requests": requests[:10],
        "completed": completed[:10],
        "span_fields": {k: dict(v.most_common(10)) for k, v in span_fields.items()},
        "examples": examples,
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thread-id")
    ap.add_argument("--marker")
    ap.add_argument("--limit", type=int, default=200000)
    args = ap.parse_args()
    state = get_thread(args.thread_id) if args.thread_id else None
    rollout = find_rollout(args.thread_id, state) if args.thread_id else None
    result = {
        "thread_id": args.thread_id,
        "marker": args.marker,
        "state_thread": state,
        "rollout": parse_rollout(rollout) if rollout else None,
        "logs": analyze_logs(args.thread_id, args.marker, args.limit),
    }
    print(json.dumps(result, indent=2, default=str))

if __name__ == "__main__":
    main()
