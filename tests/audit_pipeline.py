#!/usr/bin/env python3
import sqlite3
import os
import importlib.util
from pathlib import Path

DEFAULT_DB = Path.home() / 'Library' / 'Application Support' / 'CodexSpeedMonitor' / 'codex_telemetry.sqlite'
DB = Path(os.environ.get('CODEX_TELEMETRY_DB', DEFAULT_DB))
ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / 'codex_telemetry_daemon.py'
CODEX_HOME = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
STATE_DB = Path(os.environ.get('CODEX_TELEMETRY_STATE_DB', CODEX_HOME / 'state_5.sqlite'))

CHECKS = [
    (
        'trusted identity has no duplicate response_id',
        "with d as (select response_id, count(*) c from trusted_codex_turns where response_id is not null and response_id!='' group by 1 having c>1) select count(*) from d",
        lambda v: v == 0,
    ),
    (
        'trusted usage excludes untracked otel aggregate spans',
        "select count(*) from trusted_codex_turns where source != 'app_response' and surface != 'cli_tracked'",
        lambda v: v == 0,
    ),
    (
        'trusted usage excludes missing thread ids',
        "select count(*) from trusted_codex_turns where thread_id is null or thread_id=''",
        lambda v: v == 0,
    ),
    (
        'trusted app usage is backed by thread metadata',
        "select count(*) from trusted_codex_turns t left join codex_thread_metadata m on m.thread_id=t.thread_id where t.source='app_response' and m.thread_id is null",
        lambda v: v == 0,
    ),
    (
        'trusted usage excludes known automation and spawned-agent threads',
        "select count(*) from trusted_codex_turns t join codex_thread_metadata m on m.thread_id=t.thread_id where coalesce(m.first_user_message,'') like 'Automation:%' or coalesce(m.parent_thread_id,'')!='' or coalesce(m.agent_role,'')!='' or coalesce(m.agent_nickname,'')!=''",
        lambda v: v == 0,
    ),
    (
        'trusted rows have model and reasoning effort',
        "select sum(model is null or model='') + sum(reasoning_effort is null or reasoning_effort='') from trusted_codex_turns",
        lambda v: v == 0,
    ),
    (
        'token arithmetic balances',
        "select sum(total_tokens != coalesce(input_tokens,0)+coalesce(output_tokens,0)) + sum(coalesce(cached_input_tokens,0)>coalesce(input_tokens,0)) + sum(coalesce(reasoning_tokens,0)>coalesce(output_tokens,0)) from trusted_codex_turns",
        lambda v: v == 0,
    ),
    (
        'speed view excludes short/noisy responses',
        "select count(*) from trusted_codex_speed_turns where duration_ms < 5000 or output_tokens < 100 or output_tokens_per_second is null or output_tokens_per_second < 0",
        lambda v: v == 0,
    ),
    (
        'speed view uses API response timings only',
        "select count(*) from trusted_codex_speed_turns where source != 'app_response'",
        lambda v: v == 0,
    ),
    (
        'speed view excludes server-side tool-usage responses',
        "select count(*) from trusted_codex_speed_turns s where exists (select 1 from json_each(case when json_valid(s.raw_json) then s.raw_json else '{\"response\":{\"tool_usage\":{}}}' end, '$.response.tool_usage') tool where coalesce(json_extract(tool.value, '$.total_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.input_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.output_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.input_tokens_details.image_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.input_tokens_details.text_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.output_tokens_details.image_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.output_tokens_details.text_tokens'), 0) > 0 or coalesce(json_extract(tool.value, '$.num_requests'), 0) > 0)",
        lambda v: v == 0,
    ),
    (
        'speed formula matches output tokens divided by duration',
        "select count(*) from trusted_codex_speed_turns where abs(output_tokens_per_second - (1.0*output_tokens/(duration_ms/1000.0))) > 0.000001",
        lambda v: v == 0,
    ),
]


def scalar(conn, sql):
    return conn.execute(sql).fetchone()[0]


def main():
    spec = importlib.util.spec_from_file_location('codex_telemetry_daemon', DAEMON)
    ctd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ctd)
    conn = ctd.connect(DB)
    ctd.ingest_thread_metadata(conn, STATE_DB)
    ctd.refresh_turn_observations(conn)
    conn.commit()
    conn.row_factory = sqlite3.Row
    failures = []
    print(f'DB: {DB}')
    trusted = scalar(conn, 'select count(*) from trusted_codex_turns')
    speed = scalar(conn, 'select count(*) from trusted_codex_speed_turns')
    print(f'trusted_responses={trusted}')
    print(f'speed_eligible_responses={speed}')
    print(f'excluded_from_speed={trusted - speed}')
    for label, sql, ok in CHECKS:
        value = scalar(conn, sql) or 0
        status = 'PASS' if ok(value) else 'FAIL'
        print(f'{status} {label}: {value}')
        if status == 'FAIL':
            failures.append(label)
    print('\nmode summary')
    for row in conn.execute("select mode, count(*) responses, round(avg(output_tokens_per_second),2) avg_output_tps from trusted_codex_speed_turns group by 1 order by responses desc"):
        print(dict(row))
    print('\nreasoning summary')
    for row in conn.execute("select reasoning_effort, count(*) responses, round(avg(output_tokens_per_second),2) avg_output_tps from trusted_codex_speed_turns group by 1 order by responses desc"):
        print(dict(row))
    conn.close()
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
