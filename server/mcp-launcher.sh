#!/usr/bin/env bash
# coding-buddy MCP server launcher — resolves bun, then execs the server.
# Failing here with a clear stderr message is much easier to debug than a silent
# "MCP tools not available" from Claude Code.

set -eu

# State dir resolved the way scripts/paths.sh does, without sourcing it (this
# runs before anything else and must not depend on jq).
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  STATE_DIR="$CLAUDE_CONFIG_DIR/buddy-state"
else
  STATE_DIR="$HOME/.claude-buddy"
fi
LOG="$STATE_DIR/mcp-launcher.log"

# PATH is not the same for every process Claude Code spawns, so fall back the
# way the hooks do instead of giving up on `command -v` alone.
BUN="$(command -v bun 2>/dev/null || true)"
[ -n "$BUN" ] && [ -x "$BUN" ] || BUN="$HOME/.bun/bin/bun"
[ -x "$BUN" ] || BUN="/opt/homebrew/bin/bun"
[ -x "$BUN" ] || BUN="/usr/local/bin/bun"

if [ ! -x "$BUN" ]; then
  cat >&2 <<'EOF'
[coding-buddy] ERROR: 'bun' was not found on PATH or in any known location.

coding-buddy's MCP server runs on bun. Install it with:

  Linux / macOS:
    curl -fsSL https://bun.sh/install | bash

  Windows (PowerShell):
    powershell -c "irm bun.sh/install.ps1 | iex"

Then open a new shell (so PATH picks up bun) and restart Claude Code.
EOF
  [ -d "$STATE_DIR" ] && printf '%s bun not found (PATH=%s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$PATH" >> "$LOG" 2>/dev/null
  exit 127
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Claude Code discards this process's stderr and surfaces only "server failed to
# connect", which leaves nothing to diagnose. Keep a copy on disk when we can.
if [ -d "$STATE_DIR" ] && : >> "$LOG" 2>/dev/null; then
  printf '%s starting via %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BUN" >> "$LOG"
  exec "$BUN" "$SCRIPT_DIR/index.ts" 2> >(tee -a "$LOG" >&2)
fi

exec "$BUN" "$SCRIPT_DIR/index.ts"
