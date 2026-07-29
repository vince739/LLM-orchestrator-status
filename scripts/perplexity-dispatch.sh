#!/usr/bin/env bash
# Dispatch a task spec to Perplexity's Sonar API, capture tokens/citations/timing,
# update status artifacts consumed by the Claude Code statusline.
#
# There is no official Perplexity CLI — this calls the HTTP API directly
# (Bearer auth, OpenAI-compatible chat-completions shape).
#
# Usage: perplexity-dispatch.sh <spec-file> [task-name]
#
# Spec format: plain text file. First line MAY use a model-routing prefix:
#   deep: <query>    → sonar-deep-research   (full multi-search report; expensive)
#   reason: <query>  → sonar-reasoning-pro   (CoT, grounded)
#   fast: <query>    → sonar                 (cheap quick answer)
#   (no prefix)      → $PERPLEXITY_DISPATCH_MODEL  (default sonar-pro)
#
# Env vars:
#   PERPLEXITY_API_KEY        — required
#   PERPLEXITY_DISPATCH_MODEL — default model when no prefix (default: sonar-pro)
#
# Writes:
#   ~/.claude/logs/perplexity-<ISO>.log  — full request/response trace
#   ~/.claude/perplexity-last.json       — { timestamp, task_name, model,
#                                            tokens, elapsed_s, status,
#                                            exit_code, spec_path, log_path,
#                                            chars_out, citations_count }
#
# Exit code: 0 on success, non-zero on API failure / missing key / bad spec.

set -uo pipefail

SPEC_FILE="${1:-}"
TASK_NAME="${2:-$(basename "${SPEC_FILE:-dispatch}" | sed 's/\.[^.]*$//')}"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: perplexity-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

if [ -z "${PERPLEXITY_API_KEY:-}" ]; then
  echo "error: PERPLEXITY_API_KEY env var is unset" >&2
  echo "       get a key at https://perplexity.ai/settings/api and add it to ~/.zshrc" >&2
  exit 3
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/perplexity-${TS_FILE}.log"
LAST_JSON="$CLAUDE_DIR/perplexity-last.json"

# Read full spec, then strip + interpret leading prefix on the first non-blank line.
RAW="$(cat "$SPEC_FILE")"
PROMPT="$RAW"
DEFAULT_MODEL="${PERPLEXITY_DISPATCH_MODEL:-sonar-pro}"
MODEL="$DEFAULT_MODEL"

case "$RAW" in
  deep:*)
    MODEL="sonar-deep-research"
    PROMPT="${RAW#deep:}"
    PROMPT="${PROMPT# }"
    ;;
  reason:*)
    MODEL="sonar-reasoning-pro"
    PROMPT="${RAW#reason:}"
    PROMPT="${PROMPT# }"
    ;;
  fast:*)
    MODEL="sonar"
    PROMPT="${RAW#fast:}"
    PROMPT="${PROMPT# }"
    ;;
esac

{
  echo "── perplexity-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec:  $SPEC_FILE"
  echo "model: $MODEL"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(date +%s)"

# Build JSON request body via python3 (safe escaping of arbitrary prompt content).
REQ_BODY="$(MODEL="$MODEL" PROMPT="$PROMPT" python3 - <<'PY'
import json, os
print(json.dumps({
    "model":    os.environ["MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
}))
PY
)"

RESPONSE_FILE="$LOG_DIR/perplexity-${TS_FILE}.response.json"

HTTP_CODE="$(curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" \
  -X POST https://api.perplexity.ai/chat/completions \
  -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$REQ_BODY" 2>>"$LOG_FILE")"
CURL_EXIT=$?

END_EPOCH="$(date +%s)"
ELAPSED="$(( END_EPOCH - START_EPOCH ))"

# Tee response into the main log for grep-ability later.
{
  echo "── response (http $HTTP_CODE) ──"
  cat "$RESPONSE_FILE" 2>/dev/null
  echo ""
} | tee -a "$LOG_FILE" >/dev/null

if [ "$CURL_EXIT" -ne 0 ]; then
  STATUS="failed"
  EXIT_CODE="$CURL_EXIT"
elif [ "$HTTP_CODE" != "200" ]; then
  STATUS="failed"
  EXIT_CODE=1
else
  STATUS="success"
  EXIT_CODE=0
fi

# Extract tokens, content, citations from the response JSON. Tolerate
# Perplexity's two citation shapes: top-level `citations` (legacy) and
# `search_results` (newer Sonar models).
PARSED="$(RESPONSE_FILE="$RESPONSE_FILE" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["RESPONSE_FILE"]) as f:
        doc = json.load(f)
except Exception:
    print(json.dumps({"tokens": 0, "chars_out": 0, "citations_count": 0, "content": ""}))
    sys.exit(0)
usage = doc.get("usage") or {}
tokens = int(usage.get("total_tokens") or 0)
content = ""
choices = doc.get("choices") or []
if choices:
    msg = (choices[0] or {}).get("message") or {}
    content = msg.get("content") or ""
cit = doc.get("citations")
if cit is None:
    cit = doc.get("search_results") or []
cit_count = len(cit) if isinstance(cit, list) else 0
print(json.dumps({
    "tokens": tokens,
    "chars_out": len(content),
    "citations_count": cit_count,
    "content": content,
}))
PY
)"

TOKENS="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tokens"])' 2>/dev/null || echo 0)"
CHARS_OUT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["chars_out"])' 2>/dev/null || echo 0)"
CITATIONS_COUNT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["citations_count"])' 2>/dev/null || echo 0)"
CONTENT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["content"])' 2>/dev/null || echo "")"

# Print the assistant content to stdout (the user/caller wants to see it).
if [ -n "$CONTENT" ]; then
  printf "%s\n" "$CONTENT" | tee -a "$LOG_FILE"
fi

TASK_NAME="$TASK_NAME" MODEL="$MODEL" TOKENS="$TOKENS" ELAPSED="$ELAPSED" \
STATUS="$STATUS" EXIT_CODE="$EXIT_CODE" SPEC_FILE="$SPEC_FILE" \
LOG_FILE="$LOG_FILE" CHARS_OUT="$CHARS_OUT" CITATIONS_COUNT="$CITATIONS_COUNT" \
HTTP_CODE="$HTTP_CODE" \
python3 - > "$LAST_JSON" <<'PY'
import json, os
from datetime import datetime, timezone
print(json.dumps({
  "timestamp":       datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":       os.environ.get("TASK_NAME", ""),
  "model":           os.environ.get("MODEL", "unknown"),
  "tokens":          int(os.environ.get("TOKENS") or 0),
  "elapsed_s":       int(os.environ.get("ELAPSED") or 0),
  "status":          os.environ.get("STATUS", "unknown"),
  "exit_code":       int(os.environ.get("EXIT_CODE") or 0),
  "http_code":       os.environ.get("HTTP_CODE", ""),
  "spec_path":       os.environ.get("SPEC_FILE", ""),
  "log_path":        os.environ.get("LOG_FILE", ""),
  "chars_out":       int(os.environ.get("CHARS_OUT") or 0),
  "citations_count": int(os.environ.get("CITATIONS_COUNT") or 0),
}, indent=2))
PY

{
  echo ""
  echo "── perplexity-dispatch done: status=$STATUS model=$MODEL tokens=$TOKENS citations=$CITATIONS_COUNT elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
