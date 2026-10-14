#!/usr/bin/env bash
# Claude Code status line — shows Claude context/rate-limits, Codex,
# Antigravity (agy), and Perplexity dispatch activity on up to four rows.
# Writes a session-state cache
# to ~/.claude/.session-state.json that the /budget-check and /execute-at-reset
# slash commands and the auto-budget-check hook read.

input=$(cat)

# ── Write session state cache so slash commands can read current rate-limit
# state without re-plumbing Claude Code's internal session info. Statusline
# already gets this every ~10s via stdin, so it's the cheapest capture point.
SESSION_STATE="$HOME/.claude/.session-state.json"
echo "$input" | jq --arg ts "$(date -u +%s)" '{
  timestamp: ($ts | tonumber),
  model: (.model.display_name // null),
  context_window: (.context_window // {}),
  rate_limits: (.rate_limits // {}),
  cost: (.cost // {}),
  cwd: (.workspace.current_dir // .cwd // null)
}' > "$SESSION_STATE" 2>/dev/null || true

# ── Colors (truecolor — bypasses terminal theme remapping) ────────────────────
RESET='\033[0m'
DIM='\033[2m'
BOLD='\033[1m'
GRAY='\033[38;2;110;120;130m'
WHITE='\033[38;2;230;230;230m'
CYAN='\033[38;2;100;210;230m'
GREEN='\033[38;2;80;220;120m'
YELLOW='\033[38;2;240;200;80m'
RED='\033[38;2;230;90;90m'
ORANGE='\033[38;2;230;150;60m'
SILVER='\033[38;2;200;210;220m'
CODEX_GREEN='\033[38;2;16;163;127m'
AGY_PURPLE='\033[38;2;156;93;247m'
PERPLEXITY_TEAL='\033[38;2;32;178;170m'

SEP="${GRAY} | ${RESET}"

# ── Helpers ───────────────────────────────────────────────────────────────────
pct_color() {
  local p=$1
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  # Smooth RGB gradient: green (80,220,120) → yellow (240,200,80) → red (230,90,90)
  local r g b
  if [ "$p" -le 50 ]; then
    r=$(awk "BEGIN{printf \"%d\", 80  + ($p/50)*(240-80)  + 0.5}")
    g=$(awk "BEGIN{printf \"%d\", 220 + ($p/50)*(200-220) + 0.5}")
    b=$(awk "BEGIN{printf \"%d\", 120 + ($p/50)*(80-120)  + 0.5}")
  else
    local x=$((p - 50))
    r=$(awk "BEGIN{printf \"%d\", 240 + ($x/50)*(230-240) + 0.5}")
    g=$(awk "BEGIN{printf \"%d\", 200 + ($x/50)*(90-200)  + 0.5}")
    b=$(awk "BEGIN{printf \"%d\", 80  + ($x/50)*(90-80)   + 0.5}")
  fi
  echo "\033[38;2;${r};${g};${b}m"
}

# make_bar <percent 0-100> [width=10] — gradient bar with 1/8th resolution
make_bar() {
  local pct=$1
  local width=${2:-10}
  local max_eighths=$((width * 8))
  local total_eighths
  total_eighths=$(awk "BEGIN{printf \"%d\", ($pct/100)*$max_eighths + 0.5}")
  [ "$total_eighths" -lt 0 ] && total_eighths=0
  [ "$total_eighths" -gt "$max_eighths" ] && total_eighths=$max_eighths
  [ "$pct" -gt 0 ] && [ "$total_eighths" -eq 0 ] && total_eighths=1

  local full=$((total_eighths / 8))
  local rem=$((total_eighths % 8))
  local empty=$((width - full))
  [ "$rem" -gt 0 ] && empty=$((empty - 1))

  local partials=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local color
  color=$(pct_color "$pct")

  local bar=""
  local i
  for ((i=0; i<full; i++));  do bar+="█"; done
  [ "$rem" -gt 0 ] && bar+="${partials[$rem]}"
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "${GRAY}[${color}%s${GRAY}]${RESET}" "$bar"
}

# Format time until a reset target as e.g. "1h 49m". Accepts either a Unix
# epoch integer (what Claude Code sends via stdin) or an ISO-8601 string.
# Optional 2nd arg: window seconds. If the target is in the past, advance
# it by the window size until it's in the future. This handles CC's staleness
# where resets_at lags ~minutes behind when the rolling window actually rolls.
time_until() {
  local v=$1
  local window=${2:-0}
  [ -z "$v" ] || [ "$v" = "null" ] && return
  local target_sec
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    target_sec=$v
  else
    local clean="$v"
    case "$clean" in
      *.*Z)  clean="${clean%.*}Z" ;;
      *.*)   clean="${clean%.*}Z" ;;
      *Z)    : ;;
      *)     clean="${clean}Z" ;;
    esac
    target_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null)
    [ -z "$target_sec" ] && return
  fi
  local now_sec diff_sec
  now_sec=$(date -u +%s)
  diff_sec=$((target_sec - now_sec))
  if [ "$diff_sec" -le 0 ] && [ "$window" -gt 0 ]; then
    while [ "$diff_sec" -le 0 ]; do
      target_sec=$((target_sec + window))
      diff_sec=$((target_sec - now_sec))
    done
  fi
  [ "$diff_sec" -le 0 ] && return
  local d=$((diff_sec / 86400))
  local h=$(((diff_sec % 86400) / 3600))
  local m=$(((diff_sec % 3600) / 60))
  local s=$((diff_sec % 60))
  if   [ "$d" -gt 0 ]; then printf "%dd %dh" "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf "%dh %dm" "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf "%dm" "$m"
  else printf "%ds" "$s"
  fi
}

# Format a reset target as local HH:MM. Accepts the same input shapes as
# time_until (Unix epoch or ISO-8601). Rolls the target forward by `window`
# when the source timestamp is stale (Claude Code's resets_at can lag the
# actual rolling window).
reset_clock() {
  local v=$1
  local window=${2:-0}
  [ -z "$v" ] || [ "$v" = "null" ] && return
  local target_sec
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    target_sec=$v
  else
    local clean="$v"
    case "$clean" in
      *.*Z)  clean="${clean%.*}Z" ;;
      *.*)   clean="${clean%.*}Z" ;;
      *Z)    : ;;
      *)     clean="${clean}Z" ;;
    esac
    target_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null)
    [ -z "$target_sec" ] && return
  fi
  local now_sec
  now_sec=$(date -u +%s)
  if [ "$((target_sec - now_sec))" -le 0 ] && [ "$window" -gt 0 ]; then
    while [ "$((target_sec - now_sec))" -le 0 ]; do
      target_sec=$((target_sec + window))
    done
  fi
  date -j -f "%s" "$target_sec" "+%H:%M" 2>/dev/null
}

# spawn_refresh <script> <cache-file> <max-age-sec> — run a quota refresher
# detached when its cache is missing or older than max-age-sec. A lock file
# (honored for 120s) and the refresher's own .err file (honored for max-age)
# keep the 10-second statusline cadence from piling up or hammering a failing
# endpoint. stdio is fully redirected so Claude Code's read of this script's
# stdout never waits on the child.
spawn_refresh() {
  local script=$1 cache=$2 max_age=$3
  [ -f "$script" ] || return
  local now m
  now=$(date -u +%s)
  if [ -f "$cache" ]; then
    m=$(stat -f "%m" "$cache" 2>/dev/null || echo 0)
    [ $((now - m)) -lt "$max_age" ] && return
  fi
  if [ -f "${cache}.err" ]; then
    m=$(stat -f "%m" "${cache}.err" 2>/dev/null || echo 0)
    [ $((now - m)) -lt "$max_age" ] && return
  fi
  local lock="${cache}.refreshing"
  if [ -f "$lock" ]; then
    m=$(stat -f "%m" "$lock" 2>/dev/null || echo 0)
    [ $((now - m)) -lt 120 ] && return
  fi
  touch "$lock"
  ( nohup bash -c "bash \"$script\"; rm -f \"$lock\"" </dev/null >/dev/null 2>&1 & )
}

# ── Model ─────────────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
model_part="${ORANGE}${BOLD}${model_name}${RESET}"

# ── Context usage + bar (+ auto-compact warning at 80%) ───────────────────────
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx_int=$(printf '%.0f' "$ctx_pct")
ctx_bar=$(make_bar "$ctx_int" 10)
ctx_color=$(pct_color "$ctx_int")
if [ "$ctx_int" -ge 80 ]; then
  ctx_part="${ctx_bar} ${ctx_color}${ctx_int}%${RESET} ${RED}${BOLD}⚠${RESET}"
else
  ctx_part="${ctx_bar} ${WHITE}${ctx_int}%${RESET}"
fi

# ── 5-hour rate limit + bar + reset countdown ─────────────────────────────────
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  five_bar=$(make_bar "$five_int" 10)
  five_color=$(pct_color "$five_int")
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  five_eta=$(time_until "$five_reset" 18000)
  five_part="${five_bar} ${DIM}5h:${RESET}${five_color}${five_int}%${RESET}"
  if [ -n "$five_eta" ]; then
    five_clock=$(reset_clock "$five_reset" 18000)
    if [ -n "$five_clock" ]; then
      five_part="${five_part} ${DIM}(${five_eta} - ${five_clock})${RESET}"
    else
      five_part="${five_part} ${DIM}(${five_eta})${RESET}"
    fi
  fi
else
  five_part=""
fi

# ── Weekly rate limit + bar + reset countdown ────────────────────────────────
seven_pct=$(echo "$input" | jq -r '
  .rate_limits.weekly.used_percentage //
  .rate_limits.seven_day.used_percentage //
  empty
')
if [ -n "$seven_pct" ]; then
  seven_int=$(printf '%.0f' "$seven_pct")
  seven_bar=$(make_bar "$seven_int" 10)
  seven_color=$(pct_color "$seven_int")
  seven_reset=$(echo "$input" | jq -r '
    .rate_limits.weekly.resets_at //
    .rate_limits.seven_day.resets_at //
    empty
  ')
  seven_eta=$(time_until "$seven_reset" 604800)
  seven_part="${seven_bar} ${DIM}7d:${RESET}${seven_color}${seven_int}%${RESET}"
  if [ -n "$seven_eta" ]; then
    seven_clock=$(reset_clock "$seven_reset" 604800)
    if [ -n "$seven_clock" ]; then
      seven_part="${seven_part} ${DIM}(${seven_eta} - ${seven_clock})${RESET}"
    else
      seven_part="${seven_part} ${DIM}(${seven_eta})${RESET}"
    fi
  fi
else
  seven_part=""
fi

# ── Cache hit % + savings $ ──────────────────────────────────────────────────
cache_read=$(echo "$input" | jq -r '
  .context_window.cache_read_tokens //
  .context_window.cache_read_input_tokens //
  .usage.cache_read_input_tokens //
  0
')
input_total=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
cache_part=""
if [ "$input_total" -gt 0 ] && [ "$cache_read" -gt 0 ]; then
  cache_pct=$(awk "BEGIN{printf \"%d\", ($cache_read/$input_total)*100 + 0.5}")
  [ "$cache_pct" -gt 100 ] && cache_pct=100
  if   [ "$cache_pct" -ge 70 ]; then cache_color="${GREEN}"
  elif [ "$cache_pct" -ge 40 ]; then cache_color="${YELLOW}"
  else cache_color="${DIM}${WHITE}"
  fi
  # Savings: cache reads are ~90% cheaper than full input. Price by model tier:
  # Opus $15/1M input, Sonnet $3/1M, Haiku $0.80/1M → savings = cache * price * 0.9
  case "$model_name" in
    *[Oo]pus*)   in_price=15.00 ;;
    *[Ss]onnet*) in_price=3.00  ;;
    *[Hh]aiku*)  in_price=0.80  ;;
    *)           in_price=3.00  ;;
  esac
  saved=$(awk "BEGIN{printf \"%.2f\", ($cache_read/1000000)*$in_price*0.9}")
  cache_part="${DIM}cache:${RESET}${cache_color}${cache_pct}%${RESET} ${DIM}(saved \$${saved})${RESET}"
fi

# ── Cost ──────────────────────────────────────────────────────────────────────
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost=$(awk "BEGIN{printf \"%.2f\", $cost_usd}")
cost_part="${DIM}\$${cost}${RESET}"

# ── Session elapsed minutes ───────────────────────────────────────────────────
elapsed_ms=$(echo "$input" | jq -r '
  .cost.total_duration_ms //
  .session.duration_ms //
  .session_duration_ms //
  0
')
elapsed_min=$(awk "BEGIN{printf \"%d\", $elapsed_ms/60000}")
elapsed_part="${DIM}${elapsed_min}m${RESET}"

# ── Git branch (with dirty flag) or project basename fallback ─────────────────
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
branch=""
dirty=""
loc_part=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    # Parse GitHub owner from origin remote (disambiguates multiple git accounts)
    remote_url=$(git -C "$cwd" --no-optional-locks config --get remote.origin.url 2>/dev/null)
    owner=""
    if [ -n "$remote_url" ]; then
      url="${remote_url%.git}"
      parent="${url%/*}"
      owner="${parent##*/}"
      owner="${owner##*:}"
    fi

    # Only display @owner if it matches one of the user's locally-authenticated
    # gh accounts. Without this check, anyone who clones someone else's repo
    # would see that owner's handle in their statusline.
    is_my_account=0
    if [ -n "$owner" ] && command -v gh >/dev/null 2>&1; then
      gh_accounts_cache="$HOME/.claude/.gh-accounts-cache"
      cache_age=99999
      if [ -f "$gh_accounts_cache" ]; then
        cache_mtime=$(stat -f %m "$gh_accounts_cache" 2>/dev/null || stat -c %Y "$gh_accounts_cache" 2>/dev/null || echo 0)
        cache_age=$(( $(date +%s) - cache_mtime ))
      fi
      if [ ! -f "$gh_accounts_cache" ] || [ "$cache_age" -gt 3600 ]; then
        gh auth status 2>&1 | sed -nE 's/.*Logged in to github\.com account ([^ ]+).*/\1/p' > "$gh_accounts_cache" 2>/dev/null || true
      fi
      if [ -f "$gh_accounts_cache" ] && grep -Fxq "$owner" "$gh_accounts_cache" 2>/dev/null; then
        is_my_account=1
      fi
    fi

    if [ -n "$owner" ] && [ "$is_my_account" = "1" ]; then
      # Color by sync state:
      #   green  = clean + synced     yellow = dirty (uncommitted)
      #   orange = ahead (push)       cyan   = behind (pull)
      #   red    = diverged
      # Suffix: +N (ahead) / -N (behind) / +N/-N (diverged). No suffix when synced.
      git_dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
      ahead=0; behind=0
      if upstream=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        counts=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...${upstream}" 2>/dev/null)
        ahead=$(echo "$counts" | awk '{print $1+0}')
        behind=$(echo "$counts" | awk '{print $2+0}')
      fi
      if [ -n "$git_dirty" ]; then
        owner_color="$YELLOW"
      elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        owner_color="$RED"
      elif [ "$ahead" -gt 0 ]; then
        owner_color="$ORANGE"
      elif [ "$behind" -gt 0 ]; then
        owner_color="$CYAN"
      else
        owner_color="$GREEN"
      fi
      # Build sync suffix
      sync_suffix=""
      if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        sync_suffix="${DIM} +${ahead}/-${behind}${RESET}"
      elif [ "$ahead" -gt 0 ]; then
        sync_suffix="${DIM} +${ahead}${RESET}"
      elif [ "$behind" -gt 0 ]; then
        sync_suffix="${DIM} -${behind}${RESET}"
      fi
      loc_part="${owner_color}@${owner}${RESET}${sync_suffix}"
    else
      # No remote — fall back to branch name
      [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="${YELLOW}*${RESET}"
      loc_part="${CYAN}${branch}${RESET}${dirty}"
    fi
  else
    base=$(basename "$cwd")
    [ -n "$base" ] && loc_part="${DIM}${base}${RESET}"
  fi
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
out="${model_part}${SEP}${ctx_part}"
[ -n "$five_part" ]  && out="${out}${SEP}${five_part}"
[ -n "$seven_part" ] && out="${out}${SEP}${seven_part}"
[ -n "$cache_part" ] && out="${out}${SEP}${cache_part}"
out="${out}${SEP}${cost_part}"
out="${out}${SEP}${elapsed_part}"
[ -n "$loc_part" ]   && out="${out}${SEP}${loc_part}"

# ── Codex dispatch line (second row) ─────────────────────────────────────────
codex_line=""
codex_auth_cache="$HOME/.claude/codex-auth-cache.txt"
codex_last_json="$HOME/.claude/codex-last.json"
codex_auth_src="$HOME/.codex/auth.json"
codex_refresh="$HOME/.claude/scripts/codex-refresh-auth-cache.sh"

# Lazy refresh: regenerate cache when auth.json is newer or cache missing.
if [ -f "$codex_auth_src" ] && [ -x "$codex_refresh" ]; then
  if [ ! -f "$codex_auth_cache" ] || [ "$codex_auth_src" -nt "$codex_auth_cache" ]; then
    "$codex_refresh" >/dev/null 2>&1 || true
  fi
fi

if [ -f "$codex_auth_cache" ]; then
  codex_email=""; codex_plan=""; codex_org=""
  IFS='|' read -r codex_email codex_plan codex_org < "$codex_auth_cache" || true

  case "$codex_email" in
    ""|unknown|missing|error)
      # Only surface identity when something is wrong
      codex_part="${CODEX_GREEN}${BOLD}codex${RESET}${SEP}${RED}✗ not logged in${RESET}"
      ;;
    *)
      # Authed state — codex + plan rendered as single bold teal blob.
      codex_part="${CODEX_GREEN}${BOLD}codex${RESET}"
      if [ -n "$codex_plan" ] && [ "$codex_plan" != "unknown" ] && [ "$codex_plan" != "none" ]; then
        codex_part="${CODEX_GREEN}${BOLD}codex ${codex_plan}${RESET}"
      fi

      # Append active model. Prefer the model recorded on the last dispatch
      # (captures overrides); fall back to config.toml default.
      codex_model=""
      if [ -f "$codex_last_json" ]; then
        codex_model=$(jq -r '.model // empty' "$codex_last_json" 2>/dev/null)
      fi
      if [ -z "$codex_model" ] || [ "$codex_model" = "unknown" ]; then
        codex_model=$(grep -m1 -E '^model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null | sed 's/.*= *"//; s/".*//')
      fi
      if [ -n "$codex_model" ]; then
        # Color the model cyan when a dispatch ran in the last 10 min
        # (activation indicator — same rule as age), dim otherwise.
        codex_model_color="${DIM}"
        if [ -f "$codex_last_json" ]; then
          ct=$(jq -r '.timestamp // empty' "$codex_last_json" 2>/dev/null)
          if [ -n "$ct" ]; then
            cts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ct" +%s 2>/dev/null)
            if [ -n "$cts" ] && [ "$(( $(date -u +%s) - cts ))" -lt 600 ]; then
              codex_model_color="${CYAN}"
            fi
          fi
        fi
        codex_part="${codex_part} ${DIM}·${RESET} ${codex_model_color}${codex_model}${RESET}"

        # Reasoning-effort indicator — only when elevated (skip "none" default).
        # Colored yellow to signal "this run used extra compute."
        if [ -f "$codex_last_json" ]; then
          codex_reasoning=$(jq -r '.reasoning_effort // "none"' "$codex_last_json" 2>/dev/null)
          if [ -n "$codex_reasoning" ] && [ "$codex_reasoning" != "none" ] && [ "$codex_reasoning" != "null" ]; then
            codex_part="${codex_part} ${YELLOW}r:${codex_reasoning}${RESET}"
          fi
        fi
      fi
      ;;
  esac

  # ── REAL usage, two sources:
  #  1. LIVE: ~/.claude/codex-quota.json — the ChatGPT usage endpoint, fetched
  #     by scripts/codex-quota-refresh.sh with the OAuth token Codex stores in
  #     ~/.codex/auth.json (same call the Codex TUI's /status makes; spends no
  #     tokens). Refreshed detached when older than CODEX_QUOTA_REFRESH_SEC
  #     (default 300s) and eagerly after every dispatch.
  #  2. FALLBACK: the newest rate_limits snapshot in Codex's own session logs
  #     (rollout-*.jsonl) — OpenAI's number as of the last codex run, so it can
  #     be hours stale; rendered with a dim "snap" tag.
  # Both carry used_percent / window_minutes / resets_at per window (free tier
  # = one rolling 30d window; paid plans = 5h primary + 7d secondary).
  codex_quota_json="$HOME/.claude/codex-quota.json"
  spawn_refresh "$HOME/.claude/scripts/codex-quota-refresh.sh" "$codex_quota_json" "${CODEX_QUOTA_REFRESH_SEC:-300}"
  codex_rl_line=""
  codex_rl_src=""
  codex_rl_fetched=""
  if [ -f "$codex_quota_json" ]; then
    codex_rl_line=$(jq -c '{payload:{rate_limits:{primary:.primary,secondary:.secondary,limit_reached:.limit_reached}}}' "$codex_quota_json" 2>/dev/null)
    if [ -n "$codex_rl_line" ] && [ "$codex_rl_line" != "null" ]; then
      codex_rl_src="live"
      codex_rl_fetched=$(jq -r '.fetched_at // empty' "$codex_quota_json" 2>/dev/null)
    else
      codex_rl_line=""
    fi
  fi
  if [ -z "$codex_rl_line" ]; then
    for sf in $(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -5); do
      codex_rl_line=$(grep '"rate_limits"' "$sf" 2>/dev/null | tail -1)
      [ -n "$codex_rl_line" ] && { codex_rl_src="snap"; break; }
    done
  fi
  if [ -n "$codex_rl_line" ]; then
    for rl_key in primary secondary; do
      rl_used=$(echo "$codex_rl_line" | jq -r ".payload.rate_limits.${rl_key}.used_percent // empty" 2>/dev/null)
      [ -n "$rl_used" ] || continue
      rl_win_min=$(echo "$codex_rl_line" | jq -r ".payload.rate_limits.${rl_key}.window_minutes // 0" 2>/dev/null)
      rl_resets=$(echo "$codex_rl_line" | jq -r ".payload.rate_limits.${rl_key}.resets_at // empty" 2>/dev/null)
      rl_used_int=$(printf '%.0f' "$rl_used")
      rl_bar=$(make_bar "$rl_used_int" 6)
      rl_color=$(pct_color "$rl_used_int")
      if [ "$rl_win_min" -ge 1440 ]; then rl_lbl="$((rl_win_min / 1440))d"
      elif [ "$rl_win_min" -gt 0 ]; then rl_lbl="$((rl_win_min / 60))h"
      else rl_lbl="win"; fi
      codex_part="${codex_part}${SEP}${rl_bar} ${DIM}${rl_lbl}:${RESET}${rl_color}${rl_used_int}%${RESET}"
      # An untouched window "resets" in exactly its own length — noise; skip.
      if [ "$rl_used_int" -gt 0 ]; then
        rl_eta=$(time_until "$rl_resets" $((rl_win_min * 60)))
        [ -n "$rl_eta" ] && codex_part="${codex_part} ${DIM}(${rl_eta})${RESET}"
      fi
    done
    rl_limit=$(echo "$codex_rl_line" | jq -r '.payload.rate_limits.limit_reached // false' 2>/dev/null)
    [ "$rl_limit" = "true" ] && codex_part="${codex_part} ${RED}${BOLD}✗ limit reached${RESET}"
    # Freshness tag: live data older than 30 min, or a session-log snapshot.
    if [ "$codex_rl_src" = "live" ] && [ -n "$codex_rl_fetched" ]; then
      rl_age=$(( $(date -u +%s) - codex_rl_fetched ))
      if [ "$rl_age" -ge 1800 ]; then
        if [ "$rl_age" -ge 3600 ]; then rl_age_str="$((rl_age / 3600))h"; else rl_age_str="$((rl_age / 60))m"; fi
        codex_part="${codex_part} ${DIM}·${rl_age_str} old${RESET}"
      fi
    elif [ "$codex_rl_src" = "snap" ]; then
      codex_part="${codex_part} ${DIM}·snap${RESET}"
    fi
  fi

  # Dispatches per rolling 5h window (ChatGPT Plus limits usage by messages,
  # not tokens — Plus = 20–100/5h on GPT-5.4. Default cap=50 (midpoint);
  # override via CODEX_DISPATCH_CAP_5H env var.
  codex_cap_5h="${CODEX_DISPATCH_CAP_5H:-50}"
  dispatches_5h=0
  total_toks_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/codex-*.log; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" -ge "$cutoff_5h" ]; then
          dispatches_5h=$((dispatches_5h+1))
          t=$(grep -oE 'tokens=[0-9]+' "$f" 2>/dev/null | tail -1 | cut -d= -f2)
          [ -n "$t" ] && total_toks_5h=$((total_toks_5h + t))
        fi
      done
    fi
  fi
  dispatch_pct=$(awk "BEGIN{printf \"%d\", ($dispatches_5h/$codex_cap_5h)*100 + 0.5}")
  [ "$dispatch_pct" -gt 100 ] && dispatch_pct=100
  dispatch_bar=$(make_bar "$dispatch_pct" 6)
  dispatch_color=$(pct_color "$dispatch_pct")
  if [ "$total_toks_5h" -ge 1000 ]; then
    toks_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $total_toks_5h/1000}")
  else
    toks_5h_disp="$total_toks_5h"
  fi
  if [ -n "$codex_rl_line" ]; then
    # Real quota is on the row — the estimated cap bar would just double up.
    codex_part="${codex_part}${SEP}${WHITE}${dispatches_5h}${RESET}${DIM} sent · ${RESET}${WHITE}${toks_5h_disp}${RESET}${DIM} toks (5h)${RESET}"
  else
    codex_part="${codex_part}${SEP}${dispatch_bar} ${dispatch_color}${dispatches_5h}${RESET}${DIM}/~${codex_cap_5h} · ${RESET}${WHITE}${toks_5h_disp}${RESET}${DIM} toks (5h)${RESET}"
  fi

  if [ -f "$codex_last_json" ]; then
    codex_ts=$(jq -r '.timestamp // empty' "$codex_last_json" 2>/dev/null)
    codex_tokens=$(jq -r '.tokens // 0' "$codex_last_json" 2>/dev/null)
    codex_elapsed=$(jq -r '.elapsed_s // 0' "$codex_last_json" 2>/dev/null)
    codex_status=$(jq -r '.status // "unknown"' "$codex_last_json" 2>/dev/null)
    codex_task=$(jq -r '.task_name // empty' "$codex_last_json" 2>/dev/null)

    if [ -n "$codex_ts" ]; then
      codex_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$codex_ts" +%s 2>/dev/null)
      if [ -n "$codex_ts_sec" ]; then
        codex_now_sec=$(date -u +%s)
        codex_age_sec=$((codex_now_sec - codex_ts_sec))
        if   [ "$codex_age_sec" -lt 60 ];    then codex_age_str="${codex_age_sec}s ago"
        elif [ "$codex_age_sec" -lt 3600 ];  then codex_age_str="$((codex_age_sec / 60))m ago"
        elif [ "$codex_age_sec" -lt 86400 ]; then codex_age_str="$((codex_age_sec / 3600))h ago"
        else codex_age_str="$((codex_age_sec / 86400))d ago"
        fi

        if [ "$codex_age_sec" -lt 600 ]; then codex_age_color="${CYAN}"
        else codex_age_color="${DIM}"
        fi

        if [ "$codex_tokens" -ge 1000 ]; then
          codex_tok_disp=$(awk "BEGIN{printf \"%.1fk\", $codex_tokens/1000}")
        else
          codex_tok_disp="$codex_tokens"
        fi

        # Color failed runs red; successful runs render in normal text.
        codex_tok_color="${WHITE}"
        [ "$codex_status" = "failed" ] && codex_tok_color="${RED}"

        # Prefix task name if present.
        codex_task_str=""
        [ -n "$codex_task" ] && codex_task_str="${WHITE}${codex_task}${RESET}${DIM} · ${RESET}"

        codex_part="${codex_part}${SEP}${DIM}last:${RESET} ${codex_task_str}${codex_tok_color}${codex_tok_disp}${RESET} ${DIM}toks · ${RESET}${codex_age_color}${codex_age_str}${RESET}${DIM} · ${codex_elapsed}s${RESET}"
      fi
    fi
  else
    codex_part="${codex_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  codex_line="$codex_part"
fi

[ -n "$codex_line" ] && out="${out}\n${codex_line}"

# ── Antigravity dispatch line (third row) ────────────────────────────────────
# Mirrors Codex block but uses chars_out instead of tokens (agy does not print
# token counts to stdout in print mode). Cap default 100 per 5h — override via
# AGY_DISPATCH_CAP_5H env var. agy auths via the Google-account session shared
# with the Antigravity desktop app (no API key, no API free-tier quota).
agy_line=""
agy_last_json="$HOME/.claude/agy-last.json"

# The installer drops agy in ~/.local/bin, which may be missing from the
# statusline's non-interactive PATH.
agy_bin=""
if command -v agy >/dev/null 2>&1; then
  agy_bin="agy"
elif [ -x "$HOME/.local/bin/agy" ]; then
  agy_bin="$HOME/.local/bin/agy"
fi

if [ -n "$agy_bin" ] || [ -f "$agy_last_json" ]; then
  agy_part="${AGY_PURPLE}${BOLD}antigravity${RESET}"

  # Append active model. Prefer the model recorded on the last dispatch
  # (captures overrides); fall back to the dispatch default. Cyan when a
  # dispatch ran in the last 10 min (activation indicator), dim otherwise.
  agy_model=""
  if [ -f "$agy_last_json" ]; then
    agy_model=$(jq -r '.model // empty' "$agy_last_json" 2>/dev/null)
  fi
  [ -z "$agy_model" ] && agy_model="${AGY_DISPATCH_MODEL:-gemini-3.8-flash-medium}"
  # Strip the "gemini-" prefix for display brevity (e.g. "3.7-flash-medium")
  agy_model_short="${agy_model#gemini-}"
  agy_model_color="${DIM}"
  if [ -f "$agy_last_json" ]; then
    at=$(jq -r '.timestamp // empty' "$agy_last_json" 2>/dev/null)
    if [ -n "$at" ]; then
      ats=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$at" +%s 2>/dev/null)
      if [ -n "$ats" ] && [ "$(( $(date -u +%s) - ats ))" -lt 600 ]; then
        agy_model_color="${CYAN}"
      fi
    fi
  fi
  [ -n "$agy_model_short" ] && agy_part="${agy_part} ${DIM}·${RESET} ${agy_model_color}${agy_model_short}${RESET}"

  # ── REAL quota: ~/.claude/agy-quota.json, written by
  # scripts/agy-quota-refresh.sh from `agy -p='/usage'` (read-only, no tokens).
  # Two groups, "gemini" (Flash + Pro) and "claude/gpt", each with a weekly
  # bucket (free tier) plus a 5h bucket on Pro/Ultra, shown like Codex. Google's
  # figure lags hours behind real use, so the refresher also scans recent
  # dispatch logs for a 429 "Individual quota reached" and pins that bucket to
  # 100% used (tagged ✗429) until the reset the error named. Refreshed detached
  # when older than AGY_QUOTA_REFRESH_SEC (default 900s) and after every dispatch.
  agy_quota_json="$HOME/.claude/agy-quota.json"
  spawn_refresh "$HOME/.claude/scripts/agy-quota-refresh.sh" "$agy_quota_json" "${AGY_QUOTA_REFRESH_SEC:-900}"
  agy_has_quota=0
  if [ -f "$agy_quota_json" ]; then
    while IFS=$'\t' read -r q_short q_win q_used q_reset q_override; do
      [ -n "$q_short" ] && [ -n "$q_used" ] || continue
      q_used_int=$(printf '%.0f' "$q_used")
      q_bar=$(make_bar "$q_used_int" 6)
      q_color=$(pct_color "$q_used_int")
      agy_part="${agy_part}${SEP}${q_bar} ${DIM}${q_short} ${q_win}:${RESET}${q_color}${q_used_int}%${RESET}"
      # An untouched window "resets" in exactly its own length — noise; skip.
      if [ "$q_used_int" -gt 0 ]; then
        q_eta=$(time_until "$q_reset")
        [ -n "$q_eta" ] && agy_part="${agy_part} ${DIM}(${q_eta})${RESET}"
      fi
      [ "$q_override" = "429" ] && agy_part="${agy_part} ${RED}✗429${RESET}"
      agy_has_quota=1
    done < <(jq -r '.groups[]? | [.short, (.win // "7d"), (.used_percent // ""), (.reset_epoch // ""), (.override // "")] | @tsv' "$agy_quota_json" 2>/dev/null)
    agy_q_fetched=$(jq -r '.fetched_at // empty' "$agy_quota_json" 2>/dev/null)
    if [ "$agy_has_quota" -eq 1 ] && [ -n "$agy_q_fetched" ]; then
      agy_q_age=$(( $(date -u +%s) - agy_q_fetched ))
      [ "$agy_q_age" -ge 3600 ] && agy_part="${agy_part} ${DIM}·$((agy_q_age / 3600))h old${RESET}"
    fi
  fi
  [ "$agy_has_quota" -eq 0 ] && agy_part="${agy_part}${SEP}${DIM}quota: fetching…${RESET}"

  # Local activity in the rolling 5h window (dispatch count + output volume).
  agy_dispatches_5h=0
  agy_chars_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    agy_cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$agy_cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/agy-*.log; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" -ge "$agy_cutoff_5h" ]; then
          agy_dispatches_5h=$((agy_dispatches_5h+1))
          c=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          [ -n "$c" ] && agy_chars_5h=$((agy_chars_5h + c))
        fi
      done
    fi
  fi
  if [ "$agy_chars_5h" -ge 1000 ]; then
    agy_chars_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $agy_chars_5h/1000}")
  else
    agy_chars_5h_disp="$agy_chars_5h"
  fi
  agy_part="${agy_part}${SEP}${WHITE}${agy_dispatches_5h}${RESET}${DIM} sent · ${RESET}${WHITE}${agy_chars_5h_disp}${RESET}${DIM} chars (5h)${RESET}"

  if [ -f "$agy_last_json" ]; then
    agy_ts=$(jq -r '.timestamp // empty' "$agy_last_json" 2>/dev/null)
    agy_chars=$(jq -r '.chars_out // 0' "$agy_last_json" 2>/dev/null)
    agy_elapsed=$(jq -r '.elapsed_s // 0' "$agy_last_json" 2>/dev/null)
    agy_status=$(jq -r '.status // "unknown"' "$agy_last_json" 2>/dev/null)
    agy_task=$(jq -r '.task_name // empty' "$agy_last_json" 2>/dev/null)

    if [ -n "$agy_ts" ]; then
      agy_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$agy_ts" +%s 2>/dev/null)
      if [ -n "$agy_ts_sec" ]; then
        agy_now_sec=$(date -u +%s)
        agy_age_sec=$((agy_now_sec - agy_ts_sec))
        if   [ "$agy_age_sec" -lt 60 ];    then agy_age_str="${agy_age_sec}s ago"
        elif [ "$agy_age_sec" -lt 3600 ];  then agy_age_str="$((agy_age_sec / 60))m ago"
        elif [ "$agy_age_sec" -lt 86400 ]; then agy_age_str="$((agy_age_sec / 3600))h ago"
        else agy_age_str="$((agy_age_sec / 86400))d ago"
        fi

        if [ "$agy_age_sec" -lt 600 ]; then agy_age_color="${CYAN}"
        else agy_age_color="${DIM}"
        fi

        if [ "$agy_chars" -ge 1000 ]; then
          agy_char_disp=$(awk "BEGIN{printf \"%.1fk\", $agy_chars/1000}")
        else
          agy_char_disp="$agy_chars"
        fi

        agy_char_color="${WHITE}"
        [ "$agy_status" = "failed" ] && agy_char_color="${RED}"

        # Prefix task name if present.
        agy_task_str=""
        [ -n "$agy_task" ] && agy_task_str="${WHITE}${agy_task}${RESET}${DIM} · ${RESET}"

        agy_part="${agy_part}${SEP}${DIM}last:${RESET} ${agy_task_str}${agy_char_color}${agy_char_disp}${RESET} ${DIM}chars · ${RESET}${agy_age_color}${agy_age_str}${RESET}${DIM} · ${agy_elapsed}s${RESET}"
      fi
    fi
  else
    agy_part="${agy_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  agy_line="$agy_part"
fi

[ -n "$agy_line" ] && out="${out}\n${agy_line}"

# ── Perplexity dispatch line (fourth row) ────────────────────────────────────
# Mirrors the dispatch-row blocks above. Model varies per call based on prompt prefix
# (deep:/reason:/fast:/default), so we read it from last.json rather than a
# separate cache. Row hidden when neither PERPLEXITY_API_KEY is set nor any
# prior dispatch exists.
perplexity_line=""
perplexity_last_json="$HOME/.claude/perplexity-last.json"

if [ -n "${PERPLEXITY_API_KEY:-}" ] || [ -f "$perplexity_last_json" ]; then
  perplexity_part="${PERPLEXITY_TEAL}${BOLD}perplexity${RESET}"

  if [ -f "$perplexity_last_json" ]; then
    perplexity_model=$(jq -r '.model // empty' "$perplexity_last_json" 2>/dev/null)
    if [ -n "$perplexity_model" ]; then
      perplexity_model_short="${perplexity_model#sonar-}"
      [ "$perplexity_model_short" = "$perplexity_model" ] && perplexity_model_short="$perplexity_model"
      perplexity_model_color="${DIM}"
      pt=$(jq -r '.timestamp // empty' "$perplexity_last_json" 2>/dev/null)
      if [ -n "$pt" ]; then
        pts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$pt" +%s 2>/dev/null)
        if [ -n "$pts" ] && [ "$(( $(date -u +%s) - pts ))" -lt 600 ]; then
          perplexity_model_color="${CYAN}"
        fi
      fi
      perplexity_part="${perplexity_part} ${DIM}·${RESET} ${perplexity_model_color}${perplexity_model_short}${RESET}"
    fi
  fi

  # ── REAL money: account balance + rolling-5h spend. Perplexity has no
  # balance endpoint, but every API response reports its exact cost
  # (usage.cost.total_cost). perplexity-dispatch.sh subtracts each call from
  # ~/.claude/perplexity-balance.json (seed/sync: perplexity-set-balance.sh
  # with the number from perplexity.ai/settings/api). 5h spend is summed
  # from the saved response JSONs. Green >$2, yellow $1–2, red <$1 ($2 is
  # Perplexity's own auto-top-up threshold).
  perplexity_balance_json="$HOME/.claude/perplexity-balance.json"
  if [ -f "$perplexity_balance_json" ]; then
    pbal=$(jq -r '.balance_usd // empty' "$perplexity_balance_json" 2>/dev/null)
    if [ -n "$pbal" ]; then
      pbal_disp=$(awk "BEGIN{printf \"%.2f\", $pbal}")
      pbal_color="${GREEN}"
      awk "BEGIN{exit !($pbal < 2)}" && pbal_color="${YELLOW}"
      awk "BEGIN{exit !($pbal < 1)}" && pbal_color="${RED}${BOLD}"
      perplexity_part="${perplexity_part}${SEP}${DIM}bal:${RESET}${pbal_color}\$${pbal_disp}${RESET}"
    fi
  fi

  perplexity_dispatches_5h=0
  perplexity_cost_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    perplexity_cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$perplexity_cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/perplexity-*.response.json; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" -ge "$perplexity_cutoff_5h" ]; then
          perplexity_dispatches_5h=$((perplexity_dispatches_5h+1))
          cc=$(jq -r '.usage.cost.total_cost // 0' "$f" 2>/dev/null)
          [ -n "$cc" ] && perplexity_cost_5h=$(awk "BEGIN{printf \"%.5f\", $perplexity_cost_5h + $cc}")
        fi
      done
    fi
  fi
  perplexity_cost_5h_disp=$(awk "BEGIN{printf \"%.2f\", $perplexity_cost_5h}")
  perplexity_part="${perplexity_part}${SEP}${WHITE}${perplexity_dispatches_5h}${RESET}${DIM} sent · ${RESET}${WHITE}\$${perplexity_cost_5h_disp}${RESET}${DIM} (5h)${RESET}"

  if [ -f "$perplexity_last_json" ]; then
    perplexity_ts=$(jq -r '.timestamp // empty' "$perplexity_last_json" 2>/dev/null)
    perplexity_tokens=$(jq -r '.tokens // 0' "$perplexity_last_json" 2>/dev/null)
    perplexity_elapsed=$(jq -r '.elapsed_s // 0' "$perplexity_last_json" 2>/dev/null)
    perplexity_status=$(jq -r '.status // "unknown"' "$perplexity_last_json" 2>/dev/null)
    perplexity_task=$(jq -r '.task_name // empty' "$perplexity_last_json" 2>/dev/null)
    perplexity_cites=$(jq -r '.citations_count // 0' "$perplexity_last_json" 2>/dev/null)
    perplexity_last_cost=$(jq -r '.cost_usd // empty' "$perplexity_last_json" 2>/dev/null)

    if [ -n "$perplexity_ts" ]; then
      perplexity_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$perplexity_ts" +%s 2>/dev/null)
      if [ -n "$perplexity_ts_sec" ]; then
        perplexity_now_sec=$(date -u +%s)
        perplexity_age_sec=$((perplexity_now_sec - perplexity_ts_sec))
        if   [ "$perplexity_age_sec" -lt 60 ];    then perplexity_age_str="${perplexity_age_sec}s ago"
        elif [ "$perplexity_age_sec" -lt 3600 ];  then perplexity_age_str="$((perplexity_age_sec / 60))m ago"
        elif [ "$perplexity_age_sec" -lt 86400 ]; then perplexity_age_str="$((perplexity_age_sec / 3600))h ago"
        else perplexity_age_str="$((perplexity_age_sec / 86400))d ago"
        fi

        if [ "$perplexity_age_sec" -lt 600 ]; then perplexity_age_color="${CYAN}"
        else perplexity_age_color="${DIM}"
        fi

        if [ "$perplexity_tokens" -ge 1000 ]; then
          perplexity_tok_disp=$(awk "BEGIN{printf \"%.1fk\", $perplexity_tokens/1000}")
        else
          perplexity_tok_disp="$perplexity_tokens"
        fi

        perplexity_tok_color="${WHITE}"
        [ "$perplexity_status" = "failed" ] && perplexity_tok_color="${RED}"

        perplexity_task_str=""
        [ -n "$perplexity_task" ] && perplexity_task_str="${WHITE}${perplexity_task}${RESET}${DIM} · ${RESET}"

        perplexity_cost_str=""
        if [ -n "$perplexity_last_cost" ]; then
          perplexity_cost_str="${WHITE}\$$(awk "BEGIN{printf \"%.2f\", $perplexity_last_cost}")${RESET}${DIM} · ${RESET}"
        fi
        perplexity_part="${perplexity_part}${SEP}${DIM}last:${RESET} ${perplexity_task_str}${perplexity_cost_str}${perplexity_tok_color}${perplexity_tok_disp}${RESET} ${DIM}toks · ${RESET}${WHITE}${perplexity_cites}${RESET}${DIM} cites · ${RESET}${perplexity_age_color}${perplexity_age_str}${RESET}${DIM} · ${perplexity_elapsed}s${RESET}"
      fi
    fi
  else
    perplexity_part="${perplexity_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  perplexity_line="$perplexity_part"
fi

[ -n "$perplexity_line" ] && out="${out}\n${perplexity_line}"

printf "%b" "$out"
