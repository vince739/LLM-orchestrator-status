#!/usr/bin/env bash
# Dispatch a task spec to the Antigravity CLI (agy), capture elapsed/status,
# update status artifacts consumed by the Claude Code statusline.
#
# Usage: agy-dispatch.sh <spec-file> [task-name]
#
# Spec formats (auto-detected by extension):
#   *.txt   — plain prompt text. Fed directly as: agy --model <m> -p='...'
#   *.json  — manifest with { "prompt": "...", "attachments": ["/path/a.png", ...] }.
#             Rendered as a single prompt with @path references appended inline.
#
# Writes:
#   ~/.claude/logs/agy-<ISO>.log  — full stdout+stderr of agy run (noise-filtered)
#   ~/.claude/agy-last.json       — { timestamp, task_name, model, elapsed_s,
#                                     status, exit_code, spec_path, log_path,
#                                     chars_out, attachments }
#
# Exit code passes through from `agy` so callers can branch on failure.
#
# Auth: agy uses the Google-account session shared with the Antigravity desktop
# app — no API key needed, and it does NOT consume the Gemini API free-tier
# quota. Model list: `agy models` (gemini-3.7-flash-*, gemini-3.1-pro-*, ...).
#
# Note: agy requires the attached-flag prompt form (-p='...'); a space-separated
# `-p "prompt"` is rejected. chars_out is a proxy for output volume (no token
# counts on stdout), matching the old gemini-dispatch convention.

set -uo pipefail

SPEC_FILE="${1:-}"
TASK_NAME="${2:-$(basename "${SPEC_FILE:-dispatch}" | sed 's/\.[^.]*$//')}"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: agy-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

# The installer drops agy in ~/.local/bin, which may not be on PATH in
# non-interactive shells (hooks, statusline).
export PATH="$HOME/.local/bin:$PATH"
if ! command -v agy >/dev/null 2>&1; then
  echo "error: agy not found — install with: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  exit 127
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/agy-${TS_FILE}.log"
LAST_JSON="$CLAUDE_DIR/agy-last.json"

# Build prompt + attachment list based on spec format
PROMPT=""
ATTACHMENT_COUNT=0

case "$SPEC_FILE" in
  *.json)
    # Parse JSON manifest: { "prompt": "...", "attachments": [...] }
    PARSED="$(SPEC_FILE="$SPEC_FILE" python3 - <<'PY'
import json, os, sys
with open(os.environ["SPEC_FILE"]) as f:
    doc = json.load(f)
prompt = doc.get("prompt", "")
attachments = doc.get("attachments", []) or []
# Validate attachments exist
missing = [a for a in attachments if not os.path.isfile(a)]
if missing:
    sys.stderr.write("missing attachment(s): " + ", ".join(missing) + "\n")
    sys.exit(3)
# Build composite prompt: original prompt + @path lines
parts = [prompt]
for a in attachments:
    parts.append("@" + a)
print(json.dumps({
    "prompt": "\n\n".join(parts),
    "count":  len(attachments),
}))
PY
)"
    PARSE_EXIT=$?
    if [ "$PARSE_EXIT" -ne 0 ]; then
      echo "error: failed to parse JSON manifest (exit $PARSE_EXIT)" >&2
      exit "$PARSE_EXIT"
    fi
    PROMPT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["prompt"])')"
    ATTACHMENT_COUNT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])')"
    ;;
  *)
    PROMPT="$(cat "$SPEC_FILE")"
    ;;
esac

# Default: newest flash tier at medium effort. Override via env var — e.g.
# export AGY_DISPATCH_MODEL=gemini-3.1-pro-high   (heavy reasoning)
AGY_DISPATCH_MODEL="${AGY_DISPATCH_MODEL:-gemini-3.8-flash-medium}"

# agy's built-in print-mode timeout defaults to 5m, which agentic research
# tasks (many web searches) routinely exceed — the run dies with
# "Error: timeout waiting for response". Default to 15m; override per-run.
AGY_DISPATCH_TIMEOUT="${AGY_DISPATCH_TIMEOUT:-15m}"

{
  echo "── agy-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec:        $SPEC_FILE"
  echo "model:       $AGY_DISPATCH_MODEL"
  echo "attachments: $ATTACHMENT_COUNT"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(date +%s)"

# grep -v strips agy's glog boilerplate ("ERROR: logging before google.Init")
# so logs and chars_out reflect real output. PIPESTATUS[0] keeps agy's exit.
agy --model "$AGY_DISPATCH_MODEL" --print-timeout "$AGY_DISPATCH_TIMEOUT" -p="$PROMPT" 2>&1 \
  | grep -v 'logging before google.Init' \
  | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

END_EPOCH="$(date +%s)"
ELAPSED="$(( END_EPOCH - START_EPOCH ))"

if [ "$EXIT_CODE" -eq 0 ]; then STATUS="success"; else STATUS="failed"; fi

CHARS_OUT="$(wc -c < "$LOG_FILE" | tr -d ' ')"

TASK_NAME="$TASK_NAME" MODEL="$AGY_DISPATCH_MODEL" ELAPSED="$ELAPSED" \
STATUS="$STATUS" EXIT_CODE="$EXIT_CODE" SPEC_FILE="$SPEC_FILE" \
LOG_FILE="$LOG_FILE" CHARS_OUT="$CHARS_OUT" \
ATTACHMENT_COUNT="$ATTACHMENT_COUNT" \
python3 - > "$LAST_JSON" <<'PY'
import json, os
from datetime import datetime, timezone
print(json.dumps({
  "timestamp":   datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":   os.environ.get("TASK_NAME", ""),
  "model":       os.environ.get("MODEL", ""),
  "elapsed_s":   int(os.environ.get("ELAPSED") or 0),
  "status":      os.environ.get("STATUS", "unknown"),
  "exit_code":   int(os.environ.get("EXIT_CODE") or 0),
  "spec_path":   os.environ.get("SPEC_FILE", ""),
  "log_path":    os.environ.get("LOG_FILE", ""),
  "chars_out":   int(os.environ.get("CHARS_OUT") or 0),
  "attachments": int(os.environ.get("ATTACHMENT_COUNT") or 0),
}, indent=2))
PY

{
  echo ""
  echo "── agy-dispatch done: status=$STATUS model=$AGY_DISPATCH_MODEL chars_out=$CHARS_OUT elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
