#!/usr/bin/env bash
# Seed or re-sync the local Perplexity balance tracker.
#
# Perplexity's API reports each call's exact cost (usage.cost.total_cost)
# but has no balance endpoint, so the statusline keeps a local running
# balance: seed it with the number from perplexity.ai/settings/api, and
# every dispatch subtracts its real cost. Re-run this after topping up
# (or whenever you want to true it up against the settings page).
#
# Usage: perplexity-set-balance.sh <amount-usd>     e.g. 5.00

set -euo pipefail

AMOUNT="${1:-}"
case "$AMOUNT" in
  ''|*[!0-9.]*)
    echo "usage: perplexity-set-balance.sh <amount-usd>   e.g. 5.00" >&2
    echo "       copy the current credit balance from perplexity.ai/settings/api" >&2
    exit 2
    ;;
esac

BALANCE_JSON="$HOME/.claude/perplexity-balance.json"
AMOUNT="$AMOUNT" BALANCE_JSON="$BALANCE_JSON" python3 - <<'PY'
import json, os
from datetime import datetime, timezone
doc = {
    "balance_usd": round(float(os.environ["AMOUNT"]), 5),
    "spent_since_sync": 0.0,
    "synced_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(os.environ["BALANCE_JSON"], "w") as f:
    json.dump(doc, f, indent=2)
print(f"perplexity balance set to ${doc['balance_usd']:.2f} — statusline shows it next tick")
PY
