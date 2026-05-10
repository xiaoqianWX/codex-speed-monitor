# Open-source readiness audit

## Fixed in this pass

| Area | Risk for third-party users | Change |
|---|---|---|
| Local paths | Source and LaunchAgent referenced one user's home directory. | Runtime defaults now use `~/Library/Application Support/CodexSpeedMonitor` and `~/.codex`; scripts accept environment overrides. |
| Installation | Users had to infer LaunchAgent setup and Codex config edits. | Added `scripts/install.sh` and `scripts/uninstall.sh`. |
| Viewer build | The existing app bundle was a local artifact, not a reproducible build. | Added `scripts/build_app.sh` to build the SwiftUI menu-bar app from source. |
| Background traffic | Automations, spawned agents, unattributed app-server rows, and rows without thread IDs could appear in the main clean view. | Daemon now imports `state_5.sqlite` thread metadata and requires app responses to match non-background thread metadata before they enter `trusted_codex_turns`. |
| Old local rows | A fresh user could accidentally mix pre-install reconstructed data into the clean dataset. | First daemon startup initializes `trusted_cutover_at` when absent. |
| Data privacy | Local SQLite/log/probe files could accidentally be published. | Added `.gitignore` and README privacy guidance. |
| Health checks | Status script assumed a user-specific DB path and failed obscurely before install. | Status script now uses the portable default and reports a clear missing-DB error. |
| CLI wrapper | Wrapper assumed Homebrew on Apple Silicon. | Wrapper now resolves `codex` from common paths or `PATH`, with an override for custom installs. |

## Known release decisions

| Decision | Why it remains |
|---|---|
| License | The project needs an explicit license before publishing, but choosing MIT/Apache/GPL is a product/legal choice. |
| Signed/notarized distribution | Source install works without signing; a public binary release should add signing and notarization. |
| Backward compatibility | The daemon is tied to current Codex local log/state shapes. If Codex changes `logs_2.sqlite` or websocket log formatting, capture may need an adapter update. |
| Config ownership | The installer avoids overwriting an existing `[otel]` block. Users with custom OTel config may need to merge manually. |

## Fresh-user success path

1. Clone the repo.
2. Run `./scripts/install.sh`.
3. Restart Codex if the installer added a new `[otel]` block.
4. Send a Codex message.
5. Open the menu-bar app or run the status script.

## What not to publish

- `*.sqlite`
- `*.sqlite-wal`
- `*.sqlite-shm`
- `*.log`
- local probe JSON dumps
- locally built `.app` bundles
