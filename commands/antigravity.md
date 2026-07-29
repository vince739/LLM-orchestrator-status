---
description: Launch Google Antigravity (interactive agentic IDE) in a new window. Not a dispatch — opens a separate workspace.
argument-hint: <optional initial prompt or workspace path>
---

Launch the Antigravity agentic IDE in a new window. **This is not a dispatch target.** It opens a separate interactive workspace that controls its own browser, editor, and terminal — it does not return results to Claude Code, and there is no statusline row or cap for it.

## When to use this

Antigravity is most useful for:
- Long-horizon, multi-file refactors where you want a browser-preview loop alongside the editor.
- Tasks where the agent benefits from controlling the browser (UI testing, scraping flows, OAuth dances).
- Sessions you want to leave running while you do other work in Claude Code.

For everything else — single-shot research, mechanical code generation, multi-modal analysis — the existing dispatch system (`/dispatch-codex`, `/dispatch-gemini`, `/dispatch-perplexity`) is faster and cheaper. Antigravity is built on Gemini 3 under the hood, so for headless Gemini calls, use `/dispatch-gemini` instead.

## Run

Execute: `~/.antigravity/antigravity/bin/antigravity $ARGUMENTS &`

This forks the IDE to a new window. Claude Code keeps the foreground and remains usable. The user can switch back when Antigravity finishes (or kill it manually — no integration callback exists).
