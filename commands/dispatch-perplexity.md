---
description: Dispatch a research / reasoning query to Perplexity Sonar via the API. Pick the model with a prompt prefix.
argument-hint: <[deep:|reason:|fast:] query — e.g. "deep: state of CRDT adoption in 2026">
---

Run a one-shot Perplexity dispatch for the query below. Use this when you need **live web research with citations** (Sonar Pro / Deep Research) or **specialist reasoning** (Sonar Reasoning Pro) — both gaps the existing Codex/Gemini dispatch don't cover well.

## Model routing — first prefix on the prompt wins

| Prefix | Model | Use it for |
|---|---|---|
| `deep:`   | `sonar-deep-research` | Full multi-search synthesized report. **Expensive — $0.50–$2/run.** Closest CLI analogue to Perplexity Pro web. Use sparingly. |
| `reason:` | `sonar-reasoning-pro` | Chain-of-thought, grounded reasoning. Hard one-off problems where Codex's `gpt-5.5` isn't enough. |
| `fast:`   | `sonar`               | Cheap grounded quick answer. Recency-sensitive lookups, fact checks. |
| _(none)_  | `sonar-pro` (default) | General research with citations. Reasonable default. |

## When to prefer Perplexity over Gemini grounded search

- You want **citations baked in** without prompt-engineering the model to search.
- The query is research-shaped ("what's the latest on X", "compare A vs B with sources").
- You want a Sonar Deep Research-style multi-step report — Gemini's CLI has no equivalent flag.
- Conversely: for visual/PDF/long-context analysis, stay on Gemini.

## Cost note

Perplexity API is **pay-as-you-go**. Sonar Pro ≈ $0.04/call, Sonar Deep Research ≈ $0.50–$2/run. If you're a Pro subscriber, check `perplexity.ai/settings/api` for any included credit balance. The 5h cap (`PERPLEXITY_DISPATCH_CAP_5H`, default 100) protects the budget.

## Task

$ARGUMENTS

## Workflow

1. **Pick the prefix consciously.** Default (`sonar-pro`) is fine for ~80% of research queries. Only use `deep:` when the user actually needs a long synthesized report — it's 10–50× the cost of `sonar-pro`.

2. **Write the spec** to `/tmp/perplexity-dispatch-<short-task-name>-<unix-ts>.txt`. First line should be the full prompt (with prefix if any). For research queries, include explicit instructions:
   - Time window (e.g. "as of 2026")
   - Source quality bar (e.g. "prefer primary sources, official docs, peer-reviewed papers")
   - Output shape (bulleted summary, comparison table, narrative report)

3. **Dispatch** via `~/.claude/scripts/perplexity-dispatch.sh <spec-path> <short-task-name>`. The wrapper POSTs to `api.perplexity.ai`, captures tokens + citation count + elapsed to `~/.claude/perplexity-last.json`, and tees the full log to `~/.claude/logs/perplexity-<ts>.log`.

4. **Verify the citations.** Sonar models are excellent at citing but not infallible. Before quoting a specific claim back to the user, spot-check at least one citation URL exists and supports the claim.

5. **Report**: what was found, citation count, model used (`sonar-pro` / `sonar-deep-research` / etc.), elapsed time, and any uncited claims you flagged for follow-up.
