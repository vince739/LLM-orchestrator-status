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

For everything else — single-shot research, mechanical code generation, multi-modal analysis — the existing dispatch system (`/dispatch-codex`, `/dispatch-agy`, `/dispatch-perplexity`) is faster and cheaper. Antigravity is built on Gemini under the hood, so for headless Gemini calls, use `/dispatch-agy` (the `agy` CLI) instead.

## Run

Execute: `open -a Antigravity $ARGUMENTS`

Antigravity 2.x is an Electron app with no bundled shell CLI (the old `~/.antigravity/antigravity/bin/antigravity` symlink is dead). `open -a` launches it (pass a folder path to open a workspace). It self-updates on launch; quit the app to let the pending update install. Claude Code keeps the foreground and remains usable. The user can switch back when Antigravity finishes (or kill it manually — no integration callback exists).
