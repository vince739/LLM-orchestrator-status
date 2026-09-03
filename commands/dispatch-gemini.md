---
description: RETIRED — the Gemini CLI lane is dead; use /dispatch-agy (Antigravity CLI) instead
argument-hint: <task description>
---

The Gemini CLI dispatch lane is **retired** (2026-09-03). Google sunset the Gemini CLI, and its free API tier 429s on real workloads — web search especially. The replacement is the Antigravity CLI (`agy`), which runs the same Gemini models (3.8 Flash and newer) for free via your Google-account session.

**Do not run `gemini` or `scripts/gemini-dispatch.sh` for this task.** (The old wrapper now forwards to agy anyway.)

Instead, run the `/dispatch-agy` workflow for the task below, exactly as its command file describes — spec file, `~/.claude/scripts/agy-dispatch.sh`, smoke test, report.

## Task

$ARGUMENTS
