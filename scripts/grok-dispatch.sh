#!/usr/bin/env bash
# Dispatch a task spec to xAI's Grok Build CLI (`grok`) in READ-ONLY mode,
# capture elapsed/status/tokens, and update the artifacts the statusline reads.
#
# Usage: grok-dispatch.sh <spec-file> [task-name]
#
# The spec is plain prompt text. An optional first-line prefix picks the mode:
#   noweb:   no web or X search (pure reasoning over the pasted text)
#   (none)   web search + X/Twitter search + read-only file access in the cwd
#
# Auth: the grok.com subscription login from `grok login` (~/.grok). No API key,
# no per-call bill. The `total_cost_usd` grok reports is the API-equivalent
# estimate, recorded as cost_equiv_usd, not a charge.
#
# Safety: Grok imports Claude Code's MCP servers, skills, hooks and CLAUDE.md
# by default. Every run here turns those imports off (env vars below) and
# removes the shell, edit, write, media, scheduler, subagent and MCP-gateway
# tools, so a dispatch can read and search but cannot act.
#
# Writes:
#   ~/.claude/logs/grok-<ISO>.log         — full JSON result + stderr
#   ~/.claude/logs/grok-answer-<ISO>.md   — the answer text
#   ~/.claude/grok-last.json              — { timestamp, task_name, model, effort,
#                                             elapsed_s, status, exit_code, mode,
#                                             spec_path, log_path, answer_path,
#                                             tokens, cost_equiv_usd, chars_out }
#
# Env:
#   GROK_DISPATCH_MODEL      model id (default: ~/.claude/grok-model.txt, else grok-4.7)
#   GROK_DISPATCH_EFFORT     reasoning effort (default: model default)
#   GROK_DISPATCH_MAX_TURNS  agent turn cap (default 40)
#   GROK_DISPATCH_CWD        folder Grok may read (default: current directory)

set -uo pipefail

SPEC_FILE="${1:-}"
TASK_NAME="${2:-$(basename "${SPEC_FILE:-dispatch}" | sed 's/\.[^.]*$//')}"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: grok-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"
if ! command -v grok >/dev/null 2>&1; then
  echo "error: grok not found. Install: curl -fsSL https://x.ai/cli/install.sh | bash ; then: grok login" >&2
  exit 127
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"
TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/grok-${TS_FILE}.log"
ANSWER_FILE="$LOG_DIR/grok-answer-${TS_FILE}.md"
LAST_JSON="$CLAUDE_DIR/grok-last.json"
PROMPT_FILE="$(mktemp -t grok-prompt)"
trap 'rm -f "$PROMPT_FILE"' EXIT

MODEL="${GROK_DISPATCH_MODEL:-$(cat "$CLAUDE_DIR/grok-model.txt" 2>/dev/null || echo grok-4.7)}"
EFFORT="${GROK_DISPATCH_EFFORT:-}"
MAX_TURNS="${GROK_DISPATCH_MAX_TURNS:-40}"
WORK_DIR="${GROK_DISPATCH_CWD:-$PWD}"

# Mode prefix on the first line
MODE="web"
FIRST_LINE="$(head -n1 "$SPEC_FILE")"
case "$FIRST_LINE" in
  noweb:*) MODE="noweb"; { printf '%s\n' "${FIRST_LINE#noweb:}"; tail -n +2 "$SPEC_FILE"; } > "$PROMPT_FILE" ;;
  *)       cp "$SPEC_FILE" "$PROMPT_FILE" ;;
esac

# Turn off everything Grok would import from Claude Code / Cursor.
for v in MCPS SKILLS HOOKS AGENTS RULES; do
  export "GROK_CLAUDE_${v}_ENABLED=false" "GROK_CURSOR_${v}_ENABLED=false"
done

DENY="run_terminal_command,write,search_replace,image_gen,image_edit,image_to_video,reference_to_video"
DENY="$DENY,scheduler_create,scheduler_delete,scheduler_list,workflow,spawn_subagent,monitor"
DENY="$DENY,search_tool,use_tool,ask_user_question,send_feedback,kill_command_or_subagent"
DENY="$DENY,get_command_or_subagent_output,enter_plan_mode,exit_plan_mode,todo_write"
if [ "$MODE" = "noweb" ]; then
  DENY="$DENY,web_search,web_fetch,x_user_search,x_semantic_search,x_keyword_search,x_thread_fetch"
fi

ARGS=(--prompt-file "$PROMPT_FILE" -m "$MODEL" --output-format json --max-turns "$MAX_TURNS"
      --disallowed-tools "$DENY" --no-subagents --no-plan --cwd "$WORK_DIR")
[ -n "$EFFORT" ] && ARGS+=(--reasoning-effort "$EFFORT")

{
  echo "── grok-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec:  $SPEC_FILE"
  echo "model: $MODEL${EFFORT:+ (effort $EFFORT)}   mode: $MODE   cwd: $WORK_DIR"
  echo ""
} >&2

START_EPOCH="$(date +%s)"
grok "${ARGS[@]}" </dev/null >"$LOG_FILE" 2>"$LOG_FILE.err"
EXIT_CODE=$?
ELAPSED="$(( $(date +%s) - START_EPOCH ))"
cat "$LOG_FILE.err" >> "$LOG_FILE" 2>/dev/null; rm -f "$LOG_FILE.err"

TASK_NAME="$TASK_NAME" MODEL="$MODEL" EFFORT="$EFFORT" ELAPSED="$ELAPSED" EXIT_CODE="$EXIT_CODE" \
MODE="$MODE" SPEC_FILE="$SPEC_FILE" LOG_FILE="$LOG_FILE" ANSWER_FILE="$ANSWER_FILE" \
python3 - > "$LAST_JSON.tmp" <<'PY'
import json, os
from datetime import datetime, timezone
raw = open(os.environ["LOG_FILE"], errors="replace").read()
doc = {}
start = raw.find("{")
if start != -1:
    try:
        doc, _ = json.JSONDecoder().raw_decode(raw[start:])
    except Exception:
        doc = {}
text = doc.get("text") or ""
open(os.environ["ANSWER_FILE"], "w").write(text)
exit_code = int(os.environ.get("EXIT_CODE") or 0)
status = "success" if exit_code == 0 and text.strip() else "failed"
usage = doc.get("usage") or {}
models = list((doc.get("modelUsage") or {}).keys())
print(json.dumps({
  "timestamp":      datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":      os.environ.get("TASK_NAME", ""),
  "model":          os.environ.get("MODEL", ""),
  "served_model":   models[0] if models else "",
  "effort":         os.environ.get("EFFORT", ""),
  "mode":           os.environ.get("MODE", ""),
  "elapsed_s":      int(os.environ.get("ELAPSED") or 0),
  "status":         status,
  "exit_code":      exit_code,
  "stop_reason":    doc.get("stopReason", ""),
  "turns":          doc.get("num_turns", 0),
  "spec_path":      os.environ.get("SPEC_FILE", ""),
  "log_path":       os.environ.get("LOG_FILE", ""),
  "answer_path":    os.environ.get("ANSWER_FILE", ""),
  "tokens":         int(usage.get("total_tokens") or 0),
  "cost_equiv_usd": float(doc.get("total_cost_usd") or 0),
  "chars_out":      len(text),
}, indent=2))
PY
mv "$LAST_JSON.tmp" "$LAST_JSON"
# One line per run for the statusline's rolling 5h tally: epoch, tokens, status
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(f"{int(time.time())}\t{d[\"tokens\"]}\t{d[\"status\"]}")' "$LAST_JSON" >> "$CLAUDE_DIR/grok-history.tsv"

STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$LAST_JSON")"
cat "$ANSWER_FILE"
{
  echo ""
  echo "── grok-dispatch done: status=$STATUS model=$MODEL mode=$MODE elapsed=${ELAPSED}s ──"
  echo "answer:  $ANSWER_FILE"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} >&2

[ "$STATUS" = "success" ] && exit 0
[ "$EXIT_CODE" -ne 0 ] && exit "$EXIT_CODE"
exit 1
