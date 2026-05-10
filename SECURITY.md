# Security and privacy

Codex Speed Monitor is local-first. It does not upload telemetry to a third-party service.

## Sensitive files

Treat these as private:

- `~/Library/Application Support/CodexSpeedMonitor/codex_telemetry.sqlite`
- `~/Library/Application Support/CodexSpeedMonitor/logs/*.log`
- `~/.codex/logs_2.sqlite`
- `~/.codex/state_5.sqlite`

The telemetry database can include thread IDs, response IDs, token counts, timing, service-tier hints, and selected raw request/response JSON for auditability.

## Reporting issues

When filing an issue, do not attach raw databases or logs. Prefer:

- screenshots with private thread IDs redacted
- `codex_telemetry_status.py` output with IDs redacted
- the output of `tests/audit_pipeline.py` after removing local paths if needed

## Network behavior

The daemon listens only on `127.0.0.1:4318` for local OpenTelemetry HTTP traffic and health checks.
