#!/usr/bin/env python3
import argparse
import base64
import hashlib
import http.server
import json
import os
import sqlite3
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
create table if not exists otlp_requests (
  id integer primary key autoincrement,
  received_at text not null,
  method text not null,
  path text not null,
  content_type text,
  content_encoding text,
  body_len integer not null,
  body_sha256 text not null,
  body_text text,
  body_b64 text,
  json_valid integer not null default 0,
  top_level_keys text,
  remote_addr text
);
create index if not exists idx_otlp_requests_received_at on otlp_requests(received_at);
create index if not exists idx_otlp_requests_path on otlp_requests(path);
"""

class CaptureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CodexSpeedMonitorCapture/0.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path in ("/", "/health"):
            self._send_json(200, {"ok": True, "time": now_iso()})
        else:
            self._send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        content_type = self.headers.get("content-type")
        content_encoding = self.headers.get("content-encoding")
        sha = hashlib.sha256(body).hexdigest()
        body_text = None
        body_b64 = None
        json_valid = 0
        top_level_keys = None
        try:
            body_text = body.decode("utf-8")
            parsed = json.loads(body_text)
            json_valid = 1
            if isinstance(parsed, dict):
                top_level_keys = json.dumps(sorted(parsed.keys()))
        except Exception:
            body_b64 = base64.b64encode(body).decode("ascii")

        with self.server.db_lock:
            conn = sqlite3.connect(self.server.db_path)
            conn.executescript(SCHEMA)
            conn.execute(
                """
                insert into otlp_requests (
                  received_at, method, path, content_type, content_encoding,
                  body_len, body_sha256, body_text, body_b64, json_valid,
                  top_level_keys, remote_addr
                ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    now_iso(), self.command, self.path, content_type, content_encoding,
                    len(body), sha, body_text, body_b64, json_valid, top_level_keys,
                    self.client_address[0] if self.client_address else None,
                ),
            )
            conn.commit()
            conn.close()

        self._send_json(200, {"ok": True, "stored": True, "bytes": len(body), "sha256": sha})

    def _send_json(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")

def init_db(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.commit()
    conn.close()

def main():
    parser = argparse.ArgumentParser(description="Tiny local OTLP HTTP capture server for Codex telemetry experiments.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4318)
    default_db = Path.home() / "Library" / "Application Support" / "CodexSpeedMonitor" / "otel_capture.sqlite"
    parser.add_argument("--db", default=str(default_db))
    args = parser.parse_args()
    init_db(args.db)
    server = CaptureServer((args.host, args.port), Handler)
    server.db_path = args.db
    server.db_lock = threading.Lock()
    print(json.dumps({"event":"listening","host":args.host,"port":args.port,"db":args.db,"time":now_iso()}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()
