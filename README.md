# LLM Orchestrator + Status Line

A drop-in Claude Code setup that gives you:

1. **A multi-row statusline** showing Claude context, rate-limits (5h + 7d with absolute reset clocks), cache savings, cost, plus dedicated rows for Codex, Antigravity (agy), and Perplexity dispatch activity.
2. **Slash commands** that force-dispatch work to Codex, Antigravity, or Perplexity, budget-check a plan before committing to execution, and schedule plans for the next rate-limit window.
3. **Two hooks** that warn you before a heavy turn blows the 5h window, and rotate dispatch logs weekly so `~/.claude/logs/` doesn't grow without bound.

The core idea: keep Claude (Opus / Sonnet) on judgment, debugging, smoke-testing, and architecture. Delegate mechanical code generation and long-context / multi-modal work to Codex and Antigravity — they're cheaper, sometimes faster, and each has a capability profile the other can't match.

## Example statusline

```
Opus 4.7 (1M context) | [████░░░░░░] 38% | [██░░░░░░░░] 5h:20% (4h 52m - 05:01) | [█████▉░░░░] 7d:59% (3d 13h - 13:09) | cache:82% (saved $4.21) | $31.32 | 2797m | @yourname
codex plus · gpt-5.6-terra | [██░░░░] 8/~50 · 42.1k toks (5h) | last: scraper-api · 6.2k toks · 2m ago · 47s
antigravity · 3.7-flash-medium | [▌░░░░░] 2/~100 · 8.4k chars (5h) | last: summarize-log · 4.1k chars · 12m ago · 18s
perplexity · sonar | [▏░░░░░] 1/~100 · 2.1k toks · 20 cites (5h) | last: fact-check · 16 toks · 20 cites · 1h ago · 2s
```

Rows 2–4 only render when Codex / agy / Perplexity are set up. First row always renders.

## Prerequisites

- **Claude Code** — [download](https://claude.com/claude-code) (required; this is a Claude Code add-on)
- **jq** — `brew install jq` (statusline uses it to parse Claude Code's stdin JSON)
- **Node.js** ≥ 18 — for the two hooks (`brew install node` or nvm)
- **Python 3** — for the dispatch wrappers' JSON helpers (preinstalled on macOS)

**Optional but recommended:**
- **[Codex CLI](https://github.com/openai/codex)** — `npm install -g @openai/codex` — enables Codex dispatches and the Codex statusline row. Works on a free ChatGPT account (tight caps); Plus/Pro raise limits and unlock more models.
- **[Antigravity CLI](https://antigravity.google/docs/cli/install/)** — `curl -fsSL https://antigravity.google/cli/install.sh | bash` — installs `agy`, which enables Antigravity dispatches and the agy statusline row. Auths via your Google-account session (sign in once via the Antigravity app or on first `agy` run) — no API key, and it reaches the Gemini 3.x models the free API tier caps at ~20 requests/day.
- **[Gemini CLI](https://github.com/google-gemini/gemini-cli)** (legacy) — `npm install -g @google/gemini-cli` — the old Gemini lane. `scripts/gemini-dispatch.sh` and `/dispatch-gemini` still work as a fallback, but the statusline row now belongs to agy. Gemini CLI is sunsetting in favor of the Antigravity CLI.

The statusline degrades gracefully — if `codex` or `agy` isn't installed, those rows simply don't render.

**Platform:** Built on macOS (uses BSD `date -j` syntax and `stat -f "%m"`). Should work on Linux with `date -d` / `stat -c "%Y"` tweaks — PRs welcome.

## Install

**Fresh Mac? One command does everything** — installs Homebrew/jq/Node/Claude
Code if missing, clones this repo, installs it, merges settings.json, and
walks you through the optional Codex / Antigravity / Perplexity wiring:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vince739/LLM-orchestrator-status/main/bootstrap.sh)"
```

It skips anything already installed, so re-running is safe. When it finishes,
it prints the short list of things only you can do (logging into your Claude
and ChatGPT accounts).

**Already have the prerequisites?** Then the classic path:

```bash
git clone https://github.com/vince739/LLM-orchestrator-status.git
cd LLM-orchestrator-status
./install.sh
```

The installer:
1. Backs up any existing `~/.claude/statusline.sh`, `~/.claude/scripts/`, `~/.claude/commands/`, and `~/.claude/hooks/` targets to `~/.claude/backups/pre-install-<ts>/`
2. Symlinks this repo's files into `~/.claude/` (so `git pull` upgrades everything)
3. Prints the settings.json snippet you need to merge manually

**Manual install** — if you'd rather see what's going on:

```bash
mkdir -p ~/.claude/{scripts,commands,hooks}
cp statusline.sh ~/.claude/statusline.sh
cp scripts/*.sh ~/.claude/scripts/
cp commands/*.md ~/.claude/commands/
cp hooks/*.js ~/.claude/hooks/
chmod +x ~/.claude/statusline.sh ~/.claude/scripts/*.sh
```

Then merge `examples/settings.json` into `~/.claude/settings.json`.

## Slash commands

Once installed and the settings.json snippet is merged, these are available via the Claude Code skill picker or by typing `/<name>`:

| Command | When to use |
|---|---|
| `/dispatch-codex <task>` | Force Codex for mechanical code generation — new API endpoint mirroring an existing file, CRUD scaffold, repetitive component, etc. |
| `/dispatch-agy <task>` | Force Antigravity (agy) for long-context work (>150k input tokens), multi-modal tasks (images/PDFs), heavy reasoning (`AGY_DISPATCH_MODEL=gemini-3.1-pro-high`), or parallel-batch fan-out |
| `/dispatch-gemini <task>` | Legacy Gemini CLI lane — kept as a fallback if agy is unavailable |
| `/budget-check <plan>` | Pre-flight: does this plan fit in the remaining 5h window? Returns ✅ / ⚠️ / ❌ with concrete options |
| `/execute-at-reset <plan>` | Schedule a plan to auto-execute ~1 min after the next 5h reset (via Claude Code's `CronCreate`) |

## Hooks

| Hook | Event | What it does |
|---|---|---|
| `auto-budget-check.js` | `UserPromptSubmit` | Scans each prompt for execution-intent keywords (execute, implement, deploy, refactor…). If matched AND 5h usage ≥40%, injects a `[auto-budget]` advisory into the context so Claude sees it before starting. Escalates to 🚨 at ≥80%. |
| `weekly-maintenance.js` | `SessionStart` | Once per 7 days, rotates dispatch logs older than 30 days and refreshes the Gemini model cache. Runs in background (`child.unref()`) so session startup is never blocked. |

## Statusline

Writes `~/.claude/.session-state.json` on every tick (every ~10s). This file is the ground truth for `/budget-check`, `/execute-at-reset`, and `auto-budget-check.js` — the statusline is the only component that actually sees Claude Code's rate-limit data, so it mirrors it into a file the other components can read.

### Customization

Environment variables (set in your shell profile):

| Var | Default | Purpose |
|---|---|---|
| `CODEX_DISPATCH_CAP_5H` | `50` | Messages-per-5h cap used for the Codex usage bar. ChatGPT Plus is typically 20–100 on GPT-5; pick the midpoint or tune to your actual plan. |
| `AGY_DISPATCH_CAP_5H` | `100` | Same idea for the Antigravity (agy) usage bar. |
| `AGY_DISPATCH_MODEL` | `gemini-3.8-flash-medium` | The model the agy dispatch wrapper forces via `--model`. See `agy models` for the list; use `gemini-3.1-pro-high` for heavy reasoning runs. |
| `PERPLEXITY_DISPATCH_CAP_5H` | `100` | Same idea for the Perplexity usage bar. |
| `GEMINI_DISPATCH_CAP_5H` | `100` | Legacy — cap for the old Gemini CLI lane (no longer on the statusline). |
| `GEMINI_DISPATCH_MODEL` | `gemini-2.5-flash` | Legacy — model for the old Gemini CLI lane. |

To change the statusline colors, the gradient is defined in `pct_color()` near the top — green → yellow → red by default.

## Architecture

```
 ┌─────────────────────────────────────────┐
 │ Claude Code (you're typing here)        │
 └─────────────────────────────────────────┘
    │                           │
    │ stdin JSON every ~10s     │ hook events
    ▼                           ▼
 ┌──────────────────┐    ┌─────────────────────────┐
 │ statusline.sh    │    │ hooks/                  │
 │ - renders 4 rows │    │ - auto-budget-check.js  │
 │ - writes cache → │    │ - weekly-maintenance.js │
 └──────────────────┘    └─────────────────────────┘
           │                      │
           ▼                      ▼
    ~/.claude/.session-state.json
           │                      │
           │                      │
           ▼                      ▼
 ┌─────────────────────────────────────────┐
 │ slash commands read this cache:         │
 │  /budget-check, /execute-at-reset       │
 └─────────────────────────────────────────┘

 ┌─────────────────────────────────────────┐
 │ /dispatch-codex, /dispatch-agy,         │
 │ /dispatch-perplexity                    │
 │  → write spec to /tmp/...               │
 │  → run scripts/codex-dispatch.sh,      │
 │     scripts/agy-dispatch.sh, or         │
 │     scripts/perplexity-dispatch.sh      │
 │  → wrapper writes codex-last.json /     │
 │    agy-last.json / perplexity-last.json │
 │  → statusline picks those up next tick  │
 └─────────────────────────────────────────┘
```

## When to use what

Routing heuristics the author has settled on after ~6 weeks of daily use:

| Task profile | Executor |
|---|---|
| Judgment, debugging, architecture, security, ambiguous scope | **Claude** (don't delegate) |
| Mechanical code, ~60+ lines, mirroring an existing file's style | **Codex** (default) |
| Input > ~150k tokens (summarize log, analyze whole repo, big PDF) | **Antigravity** |
| Multi-modal input (images, screenshots, PDFs) | **Antigravity** (Codex CLI is text-only) |
| 5+ similar mechanical sub-tasks in parallel | **Antigravity** |
| Live web research with citations | **Perplexity** |
| Small edit (<30 lines) | **Claude direct** (dispatch overhead exceeds gain) |

Codex and Antigravity have rough quality parity on code generation. The bottleneck is usually spec precision and your smoke-test discipline, not the model.

## Caveats

- **Multi-modal dispatches** must stage attachments inside the working directory. Files outside it can silently fail, and the model may hallucinate from the prompt description — always cross-check extracted output against the source file.
- **Rate-limit resets are rolling, not scheduled.** Claude Code's `resets_at` is an approximation; the statusline advances it by the window size if it's stale, so your countdown won't lie even when the source timestamp has drifted.
- **The budget-check heuristics** (~2M tokens per 5h, ~8k per small edit, etc.) are eyeballed — tune them for your own plan tier by editing `commands/budget-check.md`.

## License

MIT — see [LICENSE](./LICENSE).
