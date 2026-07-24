---
description: Dispatch a non-coding query (reasoning, drafting, analysis, second opinion) to ChatGPT's GPT-5.6-terra via the Codex CLI. Uses the ChatGPT subscription — no API key.
argument-hint: <[search:] query — e.g. "search: what changed in the 2026 FTC ad-disclosure rules?">
---

Run a one-shot ChatGPT dispatch for the query below. Use this when the user wants **ChatGPT/terra's take on a non-coding question** — general reasoning, drafting, analysis, or a second opinion alongside Claude. It runs `codex exec` in **read-only mode**, so it behaves as pure chat: no file edits, no shell side effects.

Auth is the existing ChatGPT-account OAuth in `~/.codex/auth.json` (same as `/dispatch-codex`) — no `OPENAI_API_KEY` needed, and no per-call cost beyond the ChatGPT plan. **Quota is shared with Codex dispatches** (same 5h ChatGPT-plan rate limit; the statusline's Codex row reflects it).

## Prefix

| Prefix | Effect |
|---|---|
| `search:` | Enable live web search (`tools.web_search`). Use for recency-sensitive questions. |
| _(none)_ | Plain chat on model knowledge. Default. |

## Routing notes

- **Coding / codegen** still goes to `/dispatch-codex` (agentic, can edit files).
- **Citation-heavy research** still favors `/dispatch-perplexity` — Sonar bakes in citations; ChatGPT's web search doesn't cite as rigorously.
- **Long-context / multi-modal** still favors `/dispatch-gemini`.
- This dispatch is for: ChatGPT-flavored reasoning, drafting, analysis, brainstorming, or when the user explicitly asks "what does ChatGPT think".

## Task

$ARGUMENTS

## Workflow

1. **Write the spec** to `/tmp/chatgpt-dispatch-<short-task-name>-<unix-ts>.txt`. Plain text: the full prompt (with `search:` prefix on the first line if live web results are needed). Inline any needed context or file excerpts directly into the spec — read-only codex can read files, but inlining is more reliable. State the desired output shape (bullets, memo, table, etc.).

2. **Dispatch** via `~/.claude/scripts/chatgpt-dispatch.sh <spec-path> <short-task-name>`. Note: `codex exec` gets SIGKILLed inside the Claude Bash sandbox — run the dispatch with sandbox disabled, same as `/dispatch-codex`. The wrapper writes the final answer to `/tmp/chatgpt-answer-<ts>.md`, tees the full log to `~/.claude/logs/chatgpt-<ts>.log`, and summarizes to `~/.claude/chatgpt-last.json` (path to the answer file is in its `answer_path` field).

3. **Relay the answer.** Read the answer file and present it to the user **verbatim or lightly formatted** — the point of this dispatch is ChatGPT's voice/take, so don't rewrite it in your own words. If you disagree with something in it, say so separately after the relay.

4. **Report**: model used, tokens, elapsed time, and whether web search was on.

## Config knobs

- `CHATGPT_DISPATCH_MODEL` — model id (default `gpt-5.6-terra`)
- `CHATGPT_DISPATCH_CAP_5H` — advisory 5h dispatch cap (default 100; shared plan quota with Codex)
