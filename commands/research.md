---
description: Multi-source research — fan out to Perplexity Sonar Deep Research + Gemini grounded search in parallel, then synthesize.
argument-hint: <research question>
---

Run a high-quality research workflow for the question below. Fan out to **two independent research engines** in parallel, then synthesize. Closest CLI-native analogue to opening Perplexity Pro in the browser — and arguably better, because two sources catch each other's blind spots.

## Question

$ARGUMENTS

## Workflow

Use the `Workflow` tool to orchestrate the fan-out. The script should:

1. **Stage 1 — fan out in parallel** (both calls fire concurrently):
   - **Perplexity Sonar Deep Research** via `bash ~/.claude/scripts/perplexity-dispatch.sh <spec> research-perplexity`. Spec is a `.txt` file with prefix `deep: <question> — produce a comprehensive report with primary-source citations.`
   - **Gemini grounded** via `bash ~/.claude/scripts/gemini-dispatch.sh <spec> research-gemini`. Spec preamble: `Use google_search aggressively. Answer the following question with citations to primary sources, official docs, or peer-reviewed material. Question: <question>`

2. **Stage 2 — synthesize on Claude.** Read both result files (`~/.claude/perplexity-last.json` + log, `~/.claude/gemini-last.json` + log). Produce a single report that:
   - Leads with the consensus answer (where both agree).
   - Calls out disagreements explicitly — name which engine claimed what.
   - Lists merged citations, deduplicated by URL.
   - Flags any claim with only one source as "single-source — verify."

3. **Report** to the user: the synthesized report, total tokens/cost (rough — Perplexity log has tokens; Gemini log has chars), elapsed time, citation count.

## When to use this vs `/dispatch-perplexity`

- `/research` for **important** queries where you want belt-and-suspenders coverage. ~$0.50–$3 total cost.
- `/dispatch-perplexity` (no prefix or `deep:`) for **single-source** research when one engine's enough.

## Cost warning

Sonar Deep Research alone is $0.50–$2/run. Gemini grounded is essentially free. Total per `/research`: usually **under $3**. Don't run this in a tight loop.
