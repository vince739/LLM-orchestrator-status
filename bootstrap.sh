#!/usr/bin/env bash
# One-command setup for the LLM Orchestrator + Status Line on a fresh Mac.
#
# Run it with:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/vince739/LLM-orchestrator-status/main/bootstrap.sh)"
#
# What it does (each step is skipped if already done — safe to re-run):
#   1. Installs Homebrew, jq, Node.js, and Claude Code if missing
#   2. Clones this repo to ~/LLM-orchestrator-status (or pulls if present)
#   3. Runs ./install.sh (symlinks statusline, scripts, commands, hooks)
#   4. Merges the statusline + hooks config into ~/.claude/settings.json
#      (backing up the old file first)
#   5. Optionally installs the Codex CLI and Gemini CLI, and saves your
#      Gemini / Perplexity API keys to ~/.zshrc
#   6. Prints the short list of things only you can do (account logins)
#
# It never touches anyone else's accounts — all logins and keys are yours.

set -euo pipefail

REPO_URL="https://github.com/vince739/LLM-orchestrator-status.git"
REPO_DIR="$HOME/LLM-orchestrator-status"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
ZSHRC="$HOME/.zshrc"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info()  { printf '  \033[2m%s\033[0m\n' "$*"; }
fail()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# When run via `curl | bash`, stdin is the script itself — prompt via /dev/tty.
INTERACTIVE=1
if [ -t 0 ]; then
  PROMPT_SRC=/dev/stdin
elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
  PROMPT_SRC=/dev/tty
else
  INTERACTIVE=0
fi

ask() { # ask "question" -> echoes answer ("" when non-interactive)
  [ "$INTERACTIVE" -eq 1 ] || { echo ""; return; }
  local ans
  printf '  %s' "$1" > /dev/tty 2>/dev/null || printf '  %s' "$1"
  IFS= read -r ans < "$PROMPT_SRC" || ans=""
  echo "$ans"
}

confirm() { # confirm "question" -> exit status
  local a; a="$(ask "$1 [y/N] ")"
  [[ "$a" =~ ^[Yy] ]]
}

append_zshrc_once() { # append_zshrc_once "export FOO=bar" "FOO"
  local line="$1" var="$2"
  touch "$ZSHRC"
  if grep -q "export ${var}=" "$ZSHRC"; then
    ok "$var already set in ~/.zshrc — leaving it alone"
  else
    printf '\n%s\n' "$line" >> "$ZSHRC"
    ok "added $var to ~/.zshrc"
  fi
}

[ "$(uname -s)" = "Darwin" ] || fail "This installer only supports macOS."

bold ""
bold "LLM Orchestrator + Status Line — bootstrap"
info "Everything below is skipped when already installed, so re-running is safe."

# ── 1. Core dependencies ─────────────────────────────────────────────────────
step "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "already installed"
else
  info "Installing Homebrew — this will ask for your Mac password."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < "${PROMPT_SRC:-/dev/null}"
fi
# Make brew visible in THIS shell (Apple Silicon installs outside default PATH)
for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$bp" ] && eval "$("$bp" shellenv)" && break
done
command -v brew >/dev/null 2>&1 || fail "Homebrew install didn't complete. Re-run this script after fixing."

step "jq + Node.js"
command -v jq   >/dev/null 2>&1 && ok "jq already installed"   || brew install jq
command -v node >/dev/null 2>&1 && ok "node already installed" || brew install node
command -v git  >/dev/null 2>&1 || fail "git not found — run 'xcode-select --install' and re-run."

step "Claude Code"
if command -v claude >/dev/null 2>&1; then
  ok "already installed ($(claude --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  npm install -g @anthropic-ai/claude-code
  ok "installed"
fi

# ── 2. The orchestrator repo ─────────────────────────────────────────────────
step "Orchestrator repo"
if [ -d "$REPO_DIR/.git" ]; then
  ok "already cloned — pulling latest"
  git -C "$REPO_DIR" pull --ff-only || info "pull failed (local changes?) — continuing with what's there"
else
  git clone "$REPO_URL" "$REPO_DIR"
  ok "cloned to $REPO_DIR"
fi

step "Installing into ~/.claude"
( cd "$REPO_DIR" && ./install.sh )

# ── 3. settings.json merge ───────────────────────────────────────────────────
step "Wiring statusline + hooks into settings.json"
mkdir -p "$CLAUDE_DIR"
if [ -f "$SETTINGS" ]; then
  jq empty "$SETTINGS" 2>/dev/null || fail "$SETTINGS exists but isn't valid JSON — fix or delete it, then re-run."
  cp "$SETTINGS" "$SETTINGS.pre-bootstrap-$(date +%Y%m%dT%H%M%S).bak"
  info "backed up existing settings.json"
else
  echo '{}' > "$SETTINGS"
fi
tmp="$(mktemp)"
jq '
  def ensure_hook($event; $cmd):
    .hooks = (.hooks // {})
    | .hooks[$event] = (
        (.hooks[$event] // []) as $arr
        | if ($arr | map(.hooks[]?.command) | index($cmd)) != null then $arr
          else $arr + [{"hooks":[{"type":"command","command":$cmd}]}] end
      );
  .statusLine = {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 2,
    "refreshInterval": 10
  }
  | ensure_hook("UserPromptSubmit"; "node ~/.claude/hooks/auto-budget-check.js")
  | ensure_hook("SessionStart";     "node ~/.claude/hooks/weekly-maintenance.js")
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
ok "settings.json updated"

# ── 4. Optional engines ──────────────────────────────────────────────────────
step "Optional AI engines"
if [ "$INTERACTIVE" -eq 0 ]; then
  info "non-interactive run — skipping optional engines (re-run in a terminal to add them)"
else
  # Codex (ChatGPT)
  if command -v codex >/dev/null 2>&1; then
    ok "Codex CLI already installed"
  elif confirm "Install Codex CLI? Needs a ChatGPT Plus/Pro subscription."; then
    npm install -g @openai/codex
    ok "installed — you'll log in with your ChatGPT account later (see final checklist)"
  else
    info "skipped — /dispatch-codex and /dispatch-chatgpt will stay inactive"
  fi
  if command -v codex >/dev/null 2>&1; then
    mkdir -p "$HOME/.codex"
    if [ ! -f "$HOME/.codex/config.toml" ] || ! grep -q '^model *=' "$HOME/.codex/config.toml"; then
      printf 'model = "gpt-5.5"\n' >> "$HOME/.codex/config.toml"
      ok 'pinned model = "gpt-5.5" in ~/.codex/config.toml (required for ChatGPT-account Codex)'
    fi
  fi

  # Gemini
  if command -v gemini >/dev/null 2>&1; then
    ok "Gemini CLI already installed"
  elif confirm "Install Gemini CLI? Needs a free Google AI Studio API key."; then
    npm install -g @google/gemini-cli
    ok "installed"
  else
    info "skipped — /dispatch-gemini will stay inactive"
  fi
  if command -v gemini >/dev/null 2>&1; then
    gkey="$(ask "Paste your Gemini API key (from aistudio.google.com/apikey), or Enter to skip: ")"
    if [ -n "$gkey" ]; then
      append_zshrc_once "export GEMINI_API_KEY=\"$gkey\"" "GEMINI_API_KEY"
      append_zshrc_once "export GEMINI_DISPATCH_MODEL=\"gemini-2.5-flash\"" "GEMINI_DISPATCH_MODEL"
      # Point the CLI at the API key instead of Google-account OAuth (both are required)
      mkdir -p "$HOME/.gemini"
      gs="$HOME/.gemini/settings.json"
      [ -f "$gs" ] && jq empty "$gs" 2>/dev/null || echo '{}' > "$gs"
      tmp="$(mktemp)"
      jq '.security = (.security // {}) | .security.auth = (.security.auth // {}) | .security.auth.selectedType = "gemini-api-key"' \
        "$gs" > "$tmp" && mv "$tmp" "$gs"
      ok "Gemini CLI set to API-key auth"
    else
      info "no key — add 'export GEMINI_API_KEY=...' to ~/.zshrc later"
    fi
  fi

  # Perplexity (no CLI — just a key)
  pkey="$(ask "Paste your Perplexity API key (perplexity.ai/settings/api), or Enter to skip: ")"
  if [ -n "$pkey" ]; then
    append_zshrc_once "export PERPLEXITY_API_KEY=\"$pkey\"" "PERPLEXITY_API_KEY"
  else
    info "no key — /dispatch-perplexity and /research will stay inactive until you add one"
  fi
fi

# ── 5. What's left ───────────────────────────────────────────────────────────
step "Done! The few things only you can do:"
cat <<'CHECKLIST'

  1. Open a NEW terminal tab (so ~/.zshrc changes load).
  2. Run:  claude   — and log in with your Claude account (browser opens).
     You should see the multi-row status line at the bottom.
  3. If you installed Codex: run  codex  once and log in with your
     ChatGPT account, then quit it.
  4. Nice-to-haves:
       Warp terminal:  https://www.warp.dev/download
       Wispr Flow (voice dictation):  https://wisprflow.ai/downloads

  Update later with:  cd ~/LLM-orchestrator-status && git pull
  Re-running this script is always safe.

CHECKLIST
