---
description: Force-dispatch a task to the Antigravity CLI (agy) via the planner/tester workflow
argument-hint: <task description — ideally long-context, heavy-reasoning, or batch-style>
---

Run the Antigravity dispatch workflow for the task below, even if the auto-dispatch heuristics wouldn't have fired. Do NOT shortcut the spec-writing or smoke-test steps.

Antigravity CLI (`agy`) is the successor to the Gemini CLI dispatch. It auths via the Google-account session shared with the Antigravity desktop app — no API key, and it does NOT consume the Gemini API free-tier quota, so it reaches the Gemini 3.x models (`gemini-3.7-flash-*`, `gemini-3.1-pro-*`) that the API key cannot.

## When to prefer Antigravity over Codex

Antigravity is the right executor when ANY of these apply:
- **Long-context** — input > ~150k tokens (whole repo dump, large logs, big CSV/JSON, long PDFs).
- **Heavy reasoning** — set `AGY_DISPATCH_MODEL=gemini-3.1-pro-high` for the run.
- **Multi-modal** — input includes images, PDFs, or screenshots. Codex CLI is text-only.
- **Parallel batch** — 5+ similar sub-tasks to fire concurrently.
- **Codex rate-limited** — `~/.claude/codex-last.json` shows a recent rate-limit failure.

For tight pattern-following on a single file (mirror this serverless style exactly), prefer Codex.

## Task

$ARGUMENTS

## Workflow

1. **Plan.** Read the referenced files, pattern sources, and data endpoints yourself. If anything essential is missing (target path, output shape, data-source URL, attachment paths), ask before writing the spec — thin specs produce thin code.

2. **Write the spec** to `/tmp/agy-dispatch-<short-task-name>-<unix-ts>.{txt,json}`.

   **Text spec (most cases)** — `.txt` file containing the full prompt. Cover:
   - Exact target file path (if writing code)
   - 2–3 pattern files to mirror (style + error-handling conventions)
   - Data sources and expected fields
   - Output shape (JSON for APIs, component signature for UI, markdown for analyses)
   - Explicit "do not do" constraints — no npm/git/deploy, no tests/READMEs, no modifying other files

   **Multi-modal spec** — `.json` manifest:
   ```json
   {
     "prompt": "Compare these two dashboard screenshots and list every visual difference you see.",
     "attachments": ["/absolute/path/to/before.png", "/absolute/path/to/after.png"]
   }
   ```
   The wrapper appends `@/path/...` references inline. Stage attachments inside the working directory before dispatch and verify the output actually reflects the file contents — hallucination on unreadable attachments is the known failure mode inherited from the Gemini CLI.

3. **Dispatch** via `~/.claude/scripts/agy-dispatch.sh <spec-path> <short-task-name>`. The wrapper runs `agy --model $AGY_DISPATCH_MODEL -p='...'` (default `gemini-3.8-flash-medium`), captures elapsed time + exit code to `~/.claude/agy-last.json`, and tees the noise-filtered log to `~/.claude/logs/agy-<ts>.log`.

4. **Smoke-test** the output before claiming success:
   - API handler → mock `req`/`res` Node harness against live data
   - UI component → dev server + browser/curl verification
   - Analysis/summary → spot-check claims against the source data
   - Multi-modal extraction → cross-check extracted fields against the source image/PDF

5. **Fix small bugs directly** (< 10 lines). Re-dispatch only if the change is substantial. If agy fails, fall back to `/dispatch-codex`.

6. **Report**: what shipped, which bugs the smoke test caught, elapsed time, attachment count (if any), integration status.
