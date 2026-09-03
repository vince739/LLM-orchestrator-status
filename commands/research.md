---
description: Multi-source research — fan out to Perplexity Sonar Deep Research + Antigravity (agy) web search in parallel, then synthesize.
argument-hint: <research question>
---

Run a high-quality research workflow for the question below. Fan out to **two independent research engines** in parallel, then synthesize. Closest CLI-native analogue to opening Perplexity Pro in the browser — and arguably better, because two sources catch each other's blind spots.

## Question

$ARGUMENTS

## Workflow

Use the `Workflow` tool to orchestrate the fan-out. The script should:

1. **Stage 1 — fan out in parallel** (both calls fire concurrently):
   - **Perplexity Sonar Deep Research** via `bash ~/.claude/scripts/perplexity-dispatch.sh <spec> research-perplexity`. Spec is a `.txt` file with prefix `deep: <question> — produce a comprehensive report with primary-source citations.`
   - **Antigravity web search** via `bash ~/.claude/scripts/agy-dispatch.sh <spec> research-agy`. Spec preamble: `This is a RESEARCH task only — use your built-in web search and URL-reading tools aggressively; do not run shell commands or modify files. Answer the following question with citations to primary sources, official docs, or peer-reviewed material. Question: <question>`. Research runs routinely need more than agy's 5m default response window — the wrapper already sets 15m; export `AGY_DISPATCH_TIMEOUT=30m` first for very broad questions.

2. **Stage 2 — synthesize on Claude.** Read both result files (`~/.claude/perplexity-last.json` + log, `~/.claude/agy-last.json` + log). Produce a single report that:
   - Leads with the consensus answer (where both agree).
   - Calls out disagreements explicitly — name which engine claimed what.
   - Lists merged citations, deduplicated by URL.
   - Flags any claim with only one source as "single-source — verify."

3. **Report** to the user: the synthesized report, total tokens/cost (rough — Perplexity log has tokens; agy log has chars), elapsed time, citation count.

## When to use this vs `/dispatch-perplexity`

- `/research` for **important** queries where you want belt-and-suspenders coverage. ~$0.50–$3 total cost.
- `/dispatch-perplexity` (no prefix or `deep:`) for **single-source** research when one engine's enough.

## Cost warning

Sonar Deep Research alone is $0.50–$2/run. Antigravity web search is free (Google-account session). Total per `/research`: usually **under $3**. Don't run this in a tight loop.
