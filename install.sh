#!/bin/bash
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-ratelimit-bar..."

# Check prerequisites
if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Install Claude Code first."
    exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "Error: jq not found. Install with: brew install jq"
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found."
    exit 1
fi

# Copy files
cp "$SCRIPT_DIR/rate-limit-probe.py" "$CLAUDE_DIR/rate-limit-probe.py"
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/rate-limit-probe.py" "$CLAUDE_DIR/statusline.sh"

# Configure settings.json
SETTINGS="$CLAUDE_DIR/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' > "$SETTINGS"
fi

# Set statusLine
UPDATED=$(jq '.statusLine = {"type": "command", "command": "'"$CLAUDE_DIR/statusline.sh"'"}' "$SETTINGS")
echo "$UPDATED" > "$SETTINGS"

# Add SessionStart hook (merge, don't overwrite existing hooks)
UPDATED=$(jq '
  .hooks.SessionStart //= [] |
  .hooks.SessionStart |= (
    [.[] | select(.hooks | any(.command | test("rate-limit-probe")) | not)] +
    [{"hooks": [{"type": "command", "command": "python3 ~/.claude/rate-limit-probe.py >/dev/null 2>&1 &", "timeout": 5, "statusMessage": "Refreshing rate limits...", "async": true}]}]
  )
' "$SETTINGS")
echo "$UPDATED" > "$SETTINGS"

# Run first probe
echo "Running initial rate limit probe (takes ~30s)..."
python3 "$CLAUDE_DIR/rate-limit-probe.py" 2>/dev/null && echo "Done! Cache written." || echo "Probe failed (will retry on next session start)."

echo ""
echo "Installed successfully!"
echo "  statusline.sh  -> $CLAUDE_DIR/statusline.sh"
echo "  probe.py       -> $CLAUDE_DIR/rate-limit-probe.py"
echo "  hook           -> SessionStart (auto-refresh)"
echo "  auto-refresh   -> every 10 min via statusline"
echo ""
echo "Restart Claude Code to see rate limits in your status bar."
