#!/usr/bin/env bash
# RETIRED (2026-09-03): the Gemini CLI lane is dead — Google sunset the CLI,
# and the free API tier 429s on anything real (web search especially).
# Every dispatch now goes through the Antigravity CLI (agy) instead.
#
# This forwarder exists so stale callers (old skills, memories, muscle
# memory) can't land on the dead lane: it hands the spec straight to
# agy-dispatch.sh with identical arguments and exit-code semantics.
#
# Use scripts/agy-dispatch.sh (or /dispatch-agy) directly in new work.

echo "[gemini-dispatch] retired — forwarding to agy-dispatch.sh (Antigravity CLI)" >&2
exec "$(dirname "$0")/agy-dispatch.sh" "$@"
