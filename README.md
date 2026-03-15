# claude-ratelimit-bar

Show Claude Code rate limits (5-hour session + 7-day weekly) in the statusline.

```
[Opus 4.6] ▓▓░░░░░░░░ 50k/1000k | 5h:44% ↻today 19:00 7d:80% ↻Mon 10:00
~/parent/dir (main) ✓
```

## How it works

Claude Code doesn't expose rate limit data to statusline scripts. This tool works around that by:

1. **PTY Probe** (`rate-limit-probe.py`) — Spawns a headless Claude CLI session, navigates to `/status → Usage` tab, and parses the ANSI output to extract usage percentages and reset times.
2. **Statusline** (`statusline.sh`) — Reads the cached data and renders it with color-coded percentages (green < 50%, yellow 50-79%, red >= 80%).
3. **Auto-refresh** — Cache refreshes on session start (via hook) and every 10 minutes (triggered by statusline when cache is stale).

Inspired by [codexbar](https://github.com/steipete/codexbar).

## Install

```bash
git clone https://github.com/yxjxx/claude-ratelimit-bar.git
cd claude-ratelimit-bar
bash install.sh
```

Then restart Claude Code.

## Requirements

- Claude Code CLI (`claude`)
- Python 3 (uses only stdlib: `pty`, `subprocess`, `select`)
- `jq`
- macOS or Linux

## Manual refresh

```bash
python3 ~/.claude/rate-limit-probe.py
```

## What's displayed

| Field | Description |
|-------|-------------|
| `5h:44%` | 5-hour rolling window usage |
| `7d:80%` | 7-day weekly usage (all models) |
| `↻today 19:00` | Reset time in 24h format with day context |
| `(15m ago)` | Cache staleness warning (shown if >10 min old) |

## Uninstall

Remove the installed files and revert settings:

```bash
rm ~/.claude/rate-limit-probe.py ~/.claude/rate-limit-cache.json
# Then edit ~/.claude/settings.json to remove the statusLine and SessionStart hook
```
