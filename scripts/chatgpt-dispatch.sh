#!/usr/bin/env bash
# Dispatch a general (non-coding) query to ChatGPT via the Codex CLI, capture
# tokens/timing, update status artifacts consumed by the Claude Code statusline.
#
# Runs `codex exec` read-only so it behaves as pure chat (no file edits, no
# shell side effects). Uses the ChatGPT-account OAuth already configured for
# Codex — no OPENAI_API_KEY needed. Quota is shared with codex-dispatch.sh
# (same ChatGPT plan).
#
# Usage: chatgpt-dispatch.sh <spec-file> [task-name]
#
# Spec format: plain text prompt. If the first line starts with "search:",
# the prefix is stripped and live web search is enabled
# (-c tools.web_search=true; `codex exec` does not accept the tui --search flag).
#
# Env knobs:
#   CHATGPT_DISPATCH_MODEL   — model id (default: gpt-5.6-terra)
#   CHATGPT_DISPATCH_CAP_5H  — advisory 5h dispatch cap (default: 100)
#
# Writes:
#   ~/.claude/logs/chatgpt-<ISO>.log     — full stdout+stderr of codex exec
#   /tmp/chatgpt-answer-<ISO>.md         — the final answer (relay this)
#   ~/.claude/chatgpt-last.json          — { timestamp, task_name, model,
#                                            reasoning_effort, tokens,
#                                            elapsed_s, status, exit_code,
#                                            spec_path, log_path, answer_path,
#                                            web_search }
#
# Exit code passes through from `codex exec` so callers can branch on failure.

set -uo pipefail

SPEC_FILE="${1:-}"
TASK_NAME="${2:-$(basename "${SPEC_FILE:-dispatch}" .txt)}"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: chatgpt-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/chatgpt-${TS_FILE}.log"
ANSWER_FILE="/tmp/chatgpt-answer-${TS_FILE}.md"
LAST_JSON="$CLAUDE_DIR/chatgpt-last.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_REQ="${CHATGPT_DISPATCH_MODEL:-gpt-5.6-terra}"

# "search:" prefix on the first line enables live web search.
SEARCH_FLAG=()
WEB_SEARCH="false"
PROMPT="$(cat "$SPEC_FILE")"
if [ "${PROMPT#search:}" != "$PROMPT" ]; then
  PROMPT="${PROMPT#search:}"
  PROMPT="${PROMPT# }"
  SEARCH_FLAG=(-c tools.web_search=true)
  WEB_SEARCH="true"
fi

# Refresh auth cache in background (shared with codex-dispatch; cheap)
"$SCRIPT_DIR/codex-refresh-auth-cache.sh" >/dev/null 2>&1 &

{
  echo "── chatgpt-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec: $SPEC_FILE"
  echo "model: $MODEL_REQ  web_search: $WEB_SEARCH"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(date +%s)"

codex exec -s read-only --skip-git-repo-check \
  -m "$MODEL_REQ" \
  -o "$ANSWER_FILE" \
  "${SEARCH_FLAG[@]+"${SEARCH_FLAG[@]}"}" \
  "$PROMPT" < /dev/null 2>&1 \
  | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

END_EPOCH="$(date +%s)"
ELAPSED="$(( END_EPOCH - START_EPOCH ))"

if [ "$EXIT_CODE" -eq 0 ]; then STATUS="success"; else STATUS="failed"; fi

# Parse "tokens used\nNNN,NNN" block from log (case-insensitive, tolerate commas)
TOKENS="$(awk '
  tolower($0) ~ /^[[:space:]]*tokens?[[:space:]]+used/ { want=1; next }
  want {
    t=$0; gsub(/,/, "", t); gsub(/[[:space:]]/, "", t)
    if (t ~ /^[0-9]+$/) { print t; exit }
  }
' "$LOG_FILE")"
[ -z "$TOKENS" ] && TOKENS=0

# Capture active model from the "model: <id>" line Codex prints at session start.
MODEL="$(grep -m1 -E '^model:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $2}')"
[ -z "$MODEL" ] && MODEL="$MODEL_REQ"

# Capture reasoning effort from the "reasoning effort: <level>" line (default: none).
REASONING="$(grep -m1 -E '^reasoning effort:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $3}')"
[ -z "$REASONING" ] && REASONING="none"

TASK_NAME="$TASK_NAME" TOKENS="$TOKENS" ELAPSED="$ELAPSED" STATUS="$STATUS" \
EXIT_CODE="$EXIT_CODE" SPEC_FILE="$SPEC_FILE" LOG_FILE="$LOG_FILE" \
ANSWER_FILE="$ANSWER_FILE" MODEL="$MODEL" REASONING="$REASONING" \
WEB_SEARCH="$WEB_SEARCH" \
python3 - > "$LAST_JSON" <<'PY'
import json, os
from datetime import datetime, timezone
print(json.dumps({
  "timestamp":         datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":         os.environ.get("TASK_NAME", ""),
  "model":             os.environ.get("MODEL", "unknown"),
  "reasoning_effort":  os.environ.get("REASONING", "none"),
  "tokens":            int(os.environ.get("TOKENS") or 0),
  "elapsed_s":         int(os.environ.get("ELAPSED") or 0),
  "status":            os.environ.get("STATUS", "unknown"),
  "exit_code":         int(os.environ.get("EXIT_CODE") or 0),
  "spec_path":         os.environ.get("SPEC_FILE", ""),
  "log_path":          os.environ.get("LOG_FILE", ""),
  "answer_path":       os.environ.get("ANSWER_FILE", ""),
  "web_search":        os.environ.get("WEB_SEARCH", "false") == "true",
}, indent=2))
PY

{
  echo ""
  echo "── chatgpt-dispatch done: status=$STATUS model=$MODEL tokens=$TOKENS elapsed=${ELAPSED}s ──"
  echo "answer:  $ANSWER_FILE"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
