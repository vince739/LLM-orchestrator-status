#!/usr/bin/env bash
# Fetch Antigravity (agy) weekly quota for the Claude Code statusline.
#
# `agy -p='/usage'` is a read-only slash command: ~2s, spends no model tokens,
# and returns per-group weekly buckets ("Gemini Models" = Flash + Pro share one
# bucket; "Claude and GPT models" = Opus/Sonnet/GPT-OSS share another).
#
# Google's number LAGS real consumption by hours. On 2026-10-13 it read 27%
# remaining while dispatches were already failing with 429 "Individual quota
# reached ... Resets in 134h17m42s". So any 429 found in a recent dispatch log
# (~/.claude/logs/agy-*.log) overrides that model group's bucket to 0%
# remaining, with the reset time taken from the error text. The 429 is ground
# truth; /usage is the estimate. A later successful run on the same group
# clears the override (bucket refilled, or a different account signed in).
#
# Writes ~/.claude/agy-quota.json:
#   { fetched_at, source, groups: [ { id, group, name, short, win, remaining_fraction,
#       used_percent, window, reset_time, reset_epoch, override } ] }
# Free tier reports one weekly bucket per group; Pro/Ultra add a 5h bucket.
#
# On failure the previous cache is left untouched and the reason lands in
# ~/.claude/agy-quota.json.err (its mtime doubles as a retry backoff).
#
# Called lazily by the statusline (detached, when the cache is older than
# AGY_QUOTA_REFRESH_SEC, default 900s) and eagerly by agy-dispatch.sh after
# every run.

set -uo pipefail

CACHE="$HOME/.claude/agy-quota.json"
ERR="${CACHE}.err"
LOG_DIR="$HOME/.claude/logs"
AGY_QUOTA_TIMEOUT="${AGY_QUOTA_TIMEOUT:-45}"
mkdir -p "$(dirname "$CACHE")"

export PATH="$HOME/.local/bin:$PATH"
if ! command -v agy >/dev/null 2>&1; then
  echo "agy not found" > "$ERR"
  exit 0
fi

# macOS has no `timeout`; poll the background agy and kill it past the limit.
OUT="$(mktemp)"
agy --output-format json -p='/usage' > "$OUT" 2>/dev/null </dev/null &
AGY_PID=$!
waited=0
while kill -0 "$AGY_PID" 2>/dev/null && [ "$waited" -lt "$AGY_QUOTA_TIMEOUT" ]; do
  sleep 1; waited=$((waited + 1))
done
if kill -0 "$AGY_PID" 2>/dev/null; then
  kill "$AGY_PID" 2>/dev/null
  echo "agy /usage timed out after ${AGY_QUOTA_TIMEOUT}s" > "$ERR"
  rm -f "$OUT"
  exit 1
fi
wait "$AGY_PID"

TMP="$(mktemp "${CACHE}.XXXXXX")"
if OUT="$OUT" LOG_DIR="$LOG_DIR" python3 - > "$TMP" 2> "$ERR" <<'PY'
import glob, json, os, re, sys, time
from datetime import datetime, timezone

raw = open(os.environ["OUT"]).read()
start = raw.find("{")
if start < 0:
    sys.stderr.write("agy /usage returned no JSON: " + raw[:200] + "\n"); sys.exit(1)
try:
    data = json.loads(raw[start:])
except Exception as e:
    sys.stderr.write(f"agy /usage JSON parse failed: {e}\n"); sys.exit(1)

groups_in = (((data.get("command") or {}).get("data") or {}).get("groups")) or []
if not groups_in:
    sys.stderr.write("agy /usage had no quota groups: " + json.dumps(data)[:300] + "\n"); sys.exit(1)

def iso_to_epoch(s):
    try:
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp())
    except Exception:
        return None

SHORT = {"gemini": "gemini", "3p": "claude/gpt"}
WIN = {"weekly": "7d", "5h": "5h", "daily": "1d"}
groups = []
for gi, g in enumerate(groups_in):
    for b in g.get("buckets") or []:
        rf = b.get("remaining_fraction")
        used = None if rf is None else round((1 - float(rf)) * 100)
        bid = b.get("id") or ""
        window = b.get("window") or ""
        prefix = bid.split("-")[0] if bid else (g.get("name") or "x").lower().split()[0]
        groups.append({
            "id": bid or f"{prefix}-{window}",
            "group": prefix,
            "name": g.get("name"),
            "short": SHORT.get(prefix, prefix),
            "win": WIN.get(window, window or "?"),
            "remaining_fraction": rf,
            "used_percent": used,
            "window": window,
            "reset_time": b.get("reset_time"),
            "reset_epoch": iso_to_epoch(b.get("reset_time")),
            "override": None,
            "_order": (gi, 0 if window == "5h" else 1),
        })
groups.sort(key=lambda x: x["_order"])
for grp in groups:
    grp.pop("_order", None)

# 429 override: a dispatch log that hit "Individual quota reached" within a
# window that has not reset yet beats the lagging /usage estimate.
now = int(time.time())
def group_for_model(model):
    m = (model or "").lower()
    if m.startswith("gemini"):
        return "gemini"
    if m.startswith(("claude", "gpt")):
        return "3p"
    return None

def parse_resets(s):
    secs = 0
    for num, unit in re.findall(r"(\d+)([hms])", s):
        secs += int(num) * {"h": 3600, "m": 60, "s": 1}[unit]
    return secs

# First pass: when did each group last complete a run successfully? A success
# after a 429 means the bucket came back (or the account changed), so that 429
# no longer applies.
last_success = {}
logs = []
for path in glob.glob(os.path.join(os.environ["LOG_DIR"], "agy-*.log")):
    try:
        mtime = int(os.path.getmtime(path))
        if now - mtime > 8 * 86400:
            continue
        text = open(path, errors="replace").read()
    except Exception:
        continue
    m_model = re.search(r"^model:\s+(\S+)", text, re.M)
    gid = group_for_model(m_model.group(1) if m_model else "")
    if not gid:
        continue
    logs.append((mtime, gid, text))
    if "status=success" in text and "AGY_ERROR" not in text:
        last_success[gid] = max(last_success.get(gid, 0), mtime)

for mtime, gid, text in logs:
    if '"error_code":429' not in text and "quota reached" not in text.lower():
        continue
    if last_success.get(gid, 0) > mtime:
        continue
    m_reset = re.search(r"Resets in ([0-9hms]+)", text)
    if not m_reset:
        continue
    reset_epoch = mtime + parse_resets(m_reset.group(1))
    if reset_epoch <= now:
        continue
    # Apply only to the bucket of that group whose API reset time agrees with
    # the error's (within 10 min). A mismatch means the 429 belongs to a window
    # the API no longer reports: the bucket rolled over, or a different account
    # is signed in now.
    for grp in groups:
        if grp["group"] != gid or not grp["reset_epoch"]:
            continue
        if abs(grp["reset_epoch"] - reset_epoch) <= 600:
            grp["remaining_fraction"] = 0
            grp["used_percent"] = 100
            grp["override"] = "429"

print(json.dumps({"fetched_at": now, "source": "agy /usage", "groups": groups}, indent=2))
PY
then
  mv -f "$TMP" "$CACHE"
  rm -f "$ERR" "$OUT"
else
  rm -f "$TMP" "$OUT"
  exit 1
fi
