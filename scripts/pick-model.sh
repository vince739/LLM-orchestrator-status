#!/usr/bin/env bash
# pick-model.sh — scrollable picker for the default model of each dispatch lane.
#
#   pick-model            choose a lane, then a model (and effort for OpenAI)
#   pick-model codex      jump straight to a lane: codex | chatgpt | agy
#
# Arrow keys or type to filter, Enter to pick, Esc to cancel. Needs fzf.
# Writes:
#   codex   -> ~/.codex/config.toml  (model + model_reasoning_effort)
#   chatgpt -> ~/.claude/chatgpt-model.txt
#   agy     -> ~/.claude/agy-model.txt
# A one-off override still wins for a single run: AGY_DISPATCH_MODEL=...,
# CHATGPT_DISPATCH_MODEL=..., or codex exec -m ... -c model_reasoning_effort=...

set -euo pipefail

command -v fzf >/dev/null || { echo "fzf is required: brew install fzf" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

CODEX_CFG="$HOME/.codex/config.toml"
CODEX_CACHE="$HOME/.codex/models_cache.json"
CHATGPT_FILE="$HOME/.claude/chatgpt-model.txt"
AGY_FILE="$HOME/.claude/agy-model.txt"
AGY_BIN="${AGY_BIN:-$HOME/.local/bin/agy}"

FZF_OPTS=(--height=60% --reverse --border --ansi --delimiter=$'\t' --with-nth=1,2)

current_codex()   { grep -m1 -E '^model[[:space:]]*=' "$CODEX_CFG" 2>/dev/null | sed 's/.*= *"//; s/".*//'; }
current_effort()  { grep -m1 -E '^model_reasoning_effort[[:space:]]*=' "$CODEX_CFG" 2>/dev/null | sed 's/.*= *"//; s/".*//'; }
current_chatgpt() { cat "$CHATGPT_FILE" 2>/dev/null || echo "gpt-6.2-sol"; }
current_agy()     { cat "$AGY_FILE" 2>/dev/null || echo "gemini-3.8-flash-medium"; }

openai_models() {
  # slug <tab> description, listed models only, in OpenAI's own order
  jq -r '.models[] | select(.visibility == "list") | [.slug, .description] | @tsv' "$CODEX_CACHE"
}

pick_openai_model() {  # $1 = header text, $2 = current slug
  openai_models | awk -F'\t' -v cur="$2" '{ mark = ($1 == cur) ? "● " : "  "; printf "%s%s\t%s\n", mark, $1, $2 }' \
    | fzf "${FZF_OPTS[@]}" --header="$1 (current: $2)" \
    | cut -f1 | sed 's/^[● ] *//; s/^ *//'
}

pick_effort() {  # $1 = slug, $2 = current effort
  jq -r --arg s "$1" '.models[] | select(.slug == $s) | .supported_reasoning_levels[] | [.effort, .description] | @tsv' "$CODEX_CACHE" \
    | awk -F'\t' -v cur="$2" '{ mark = ($1 == cur) ? "● " : "  "; printf "%s%s\t%s\n", mark, $1, $2 }' \
    | fzf "${FZF_OPTS[@]}" --header="Reasoning effort for $1 (current: ${2:-default})" \
    | cut -f1 | sed 's/^[● ] *//; s/^ *//'
}

set_toml_key() {  # $1 = key, $2 = value
  if grep -qE "^$1[[:space:]]*=" "$CODEX_CFG"; then
    sed -i '' -E "s|^$1[[:space:]]*=.*|$1 = \"$2\"|" "$CODEX_CFG"
  else
    printf '%s = "%s"\n' "$1" "$2" | cat - "$CODEX_CFG" > "$CODEX_CFG.tmp" && mv "$CODEX_CFG.tmp" "$CODEX_CFG"
  fi
}

lane_codex() {
  local m e
  m=$(pick_openai_model "Codex default model" "$(current_codex)") || return 0
  [ -n "$m" ] || return 0
  e=$(pick_effort "$m" "$(current_effort)") || return 0
  cp "$CODEX_CFG" "$CODEX_CFG.bak-picker"
  set_toml_key model "$m"
  [ -n "$e" ] && set_toml_key model_reasoning_effort "$e"
  echo "codex default -> $m${e:+ (effort $e)}"
}

lane_chatgpt() {
  local m
  m=$(pick_openai_model "ChatGPT lane model" "$(current_chatgpt)") || return 0
  [ -n "$m" ] || return 0
  echo "$m" > "$CHATGPT_FILE"
  echo "chatgpt default -> $m"
}

lane_agy() {
  local m cur
  cur=$(current_agy)
  echo "Fetching Antigravity models..." >&2
  m=$("$AGY_BIN" models 2>/dev/null | grep -v '^Fetching' \
      | awk -F'\t' -v cur="$cur" 'NF >= 2 { mark = ($1 == cur) ? "● " : "  "; printf "%s%s\t%s\n", mark, $1, $2 }' \
      | fzf "${FZF_OPTS[@]}" --header="Antigravity default model (current: $cur)" \
      | cut -f1 | sed 's/^[● ] *//; s/^ *//') || return 0
  [ -n "$m" ] || return 0
  echo "$m" > "$AGY_FILE"
  echo "agy default -> $m"
}

lane="${1:-}"
if [ -z "$lane" ]; then
  lane=$(printf '%s\t%s\n' \
      codex   "OpenAI Codex CLI (coding)     now: $(current_codex) / $(current_effort)" \
      chatgpt "ChatGPT lane (non-coding)     now: $(current_chatgpt)" \
      agy     "Antigravity (Gemini/Claude)   now: $(current_agy)" \
    | fzf "${FZF_OPTS[@]}" --header="Which lane? (Esc to cancel)" | cut -f1) || exit 0
fi

case "$lane" in
  codex)   lane_codex ;;
  chatgpt) lane_chatgpt ;;
  agy)     lane_agy ;;
  "")      exit 0 ;;
  *) echo "unknown lane: $lane (use codex, chatgpt or agy)" >&2; exit 1 ;;
esac
