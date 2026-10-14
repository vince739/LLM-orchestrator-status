#!/usr/bin/env bash
# Fetch LIVE Codex (ChatGPT) rate-limit usage for the Claude Code statusline.
#
# Codex's session logs only carry a rate_limits snapshot as of the last
# `codex exec` run, so a quiet afternoon leaves the statusline showing a stale
# number with a rolled-forward countdown. The ChatGPT backend exposes the same
# figures on demand (the call the Codex TUI's /status makes), authenticated
# with the OAuth token Codex already stores in ~/.codex/auth.json. No model
# tokens are spent.
#
# Writes ~/.claude/codex-quota.json:
#   { fetched_at, source, plan_type, limit_reached,
#     primary:   { used_percent, window_minutes, resets_at },
#     secondary: { used_percent, window_minutes, resets_at } }
# primary/secondary mirror the rollout-*.jsonl snapshot shape so the
# statusline renders either source with the same loop.
#
# On any failure the previous cache is left untouched and the reason lands in
# ~/.claude/codex-quota.json.err (its mtime doubles as a retry backoff); the
# statusline then falls back to the session-log snapshot.
#
# Called lazily by the statusline (detached, when the cache is older than
# CODEX_QUOTA_REFRESH_SEC, default 300s) and eagerly by the codex/chatgpt
# dispatch wrappers after every run.

set -uo pipefail

AUTH_JSON="$HOME/.codex/auth.json"
CACHE="$HOME/.claude/codex-quota.json"
ERR="${CACHE}.err"
mkdir -p "$(dirname "$CACHE")"

if [ ! -f "$AUTH_JSON" ]; then
  echo "no ~/.codex/auth.json (run: codex login)" > "$ERR"
  exit 0
fi

TMP="$(mktemp "${CACHE}.XXXXXX")"
if AUTH_JSON="$AUTH_JSON" python3 - > "$TMP" 2> "$ERR" <<'PY'
import json, os, sys, time, urllib.request, urllib.error

with open(os.environ["AUTH_JSON"]) as f:
    auth = json.load(f)
tokens = (auth or {}).get("tokens") or {}
access = tokens.get("access_token") or ""
account = tokens.get("account_id") or ""
if not access:
    sys.stderr.write("auth.json has no access_token\n"); sys.exit(1)

req = urllib.request.Request(
    "https://chatgpt.com/backend-api/codex/usage",
    headers={
        "Authorization": f"Bearer {access}",
        "ChatGPT-Account-Id": account,
        "Accept": "application/json",
        "User-Agent": "codex-cli",
    },
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code} from usage endpoint (token expired? run any codex command to refresh)\n"); sys.exit(1)
except Exception as e:
    sys.stderr.write(f"usage fetch failed: {e}\n"); sys.exit(1)

rl = data.get("rate_limit") or {}
def win(w):
    w = w or {}
    if "used_percent" not in w:
        return None
    return {
        "used_percent":   w.get("used_percent", 0),
        "window_minutes": int((w.get("limit_window_seconds") or 0) // 60),
        "resets_at":      w.get("reset_at"),
    }
out = {
    "fetched_at":    int(time.time()),
    "source":        "chatgpt-usage-api",
    "plan_type":     data.get("plan_type"),
    "limit_reached": bool(rl.get("limit_reached")),
    "primary":       win(rl.get("primary_window")),
    "secondary":     win(rl.get("secondary_window")),
}
print(json.dumps(out, indent=2))
PY
then
  mv -f "$TMP" "$CACHE"
  rm -f "$ERR"
else
  rm -f "$TMP"
  exit 1
fi
