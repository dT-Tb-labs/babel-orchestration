# babel — multi-model orchestration for Claude Code

`babel` is a Claude Code **skill** that orchestrates five models
(Fable 5 / Opus / Sonnet / GPT-5.6-SOL / Gemini 3 via `agy`) across the
[superpowers](https://github.com/obra/superpowers) pipeline
(brainstorm → plan → implement → review). It injects multi-model
**debate / build-debug / acceptance-gate** into each phase so the result
exceeds what a single frontier model produces — the
[Sakana "Fugu" pattern](https://sakana.ai/) applied to a dev workflow.

> Not the JavaScript Babel transpiler. This is an AI-orchestration skill.

This repo ships **three skills** as a set, because `babel` calls the other two
as its second/third-opinion channels:

| Skill | Role | Backend |
|---|---|---|
| `babel` | Lead orchestrator: triage → phase routing → merge → gates | Claude Code (Fable 5 or Opus) |
| `cdx-sol` | Independent design / diagnosis / review channel | GPT-5.6-SOL via OpenAI Codex CLI (ChatGPT subscription) |
| `agy` | Third-opinion cross-review channel | Google Antigravity CLI (`agy`, Gemini 3) |

`babel` degrades gracefully: if `cdx-sol` or `agy` is unavailable it drops that
channel and tells you (see the degradation table in `skills/babel/SKILL.md`).
You can run `babel` with only the channels you have — the other two are optional
force multipliers, not hard requirements.

## What's in each skill

```
skills/
  babel/
    SKILL.md               # runbook: crew table, phase map, cost/safety discipline
    references/protocol.md # AI-to-AI wire format (packets, blackboard, degradation)
    references/patterns.md # per-phase playbooks (debate / build-debug / acceptance-gate)
  cdx-sol/
    SKILL.md
    cdx-sol.mjs            # background+poll wrapper around codex-companion (Node, no deps)
  agy/
    SKILL.md
    agy_pty_wrapper.py     # cross-platform PTY wrapper for agy bug #76 (pywinpty / ptyprocess)
```

## Install

Run the installer — it copies the three skills into `~/.claude/skills/` and
self-tests each channel (missing optional channels are warnings, not errors):

```bash
sh install.sh            # install + self-test
sh install.sh --check    # self-test only, no copy
```

Or copy manually:

```bash
cp -r skills/babel  skills/cdx-sol  skills/agy  ~/.claude/skills/
```

The internal references use portable `$HOME/.claude/skills/...` paths, so no
editing is needed as long as all three live under `~/.claude/skills/`.

**Minimal setup:** only `babel` + Claude Code is required. `cdx-sol` and `agy`
are optional independent-review channels — babel runs with whatever you have and
tells you when a channel is degraded off. See the "依存と最小構成" section in
`skills/babel/SKILL.md` for the Claude-only (single-channel) mode.

Then invoke from Claude Code:

```
/babel <task>
```

## Prerequisites

**babel** (lead):
- Claude Code with the `superpowers` skill set (brainstorming, writing-plans,
  executing-plans, subagent-driven-development) and the `Workflow` tool.

**cdx-sol** (optional channel):
- Node.js
- OpenAI Codex CLI / `openai-codex` plugin installed under
  `~/.claude/plugins/cache/openai-codex/codex/` (or point `CDX_SOL_COMPANION`
  at `codex-companion.mjs` directly)
- A ChatGPT subscription authenticated via `codex login`
- Self-test: `node skills/cdx-sol/cdx-sol.mjs --selftest`

**agy** (optional channel, cross-platform):
- Google Antigravity CLI (`agy`) installed and `agy auth login` completed
- Python 3.x + a PTY backend: `pywinpty` on Windows, `ptyprocess` on
  Linux/macOS (`pip install pywinpty` / `pip install ptyprocess`)
- The wrapper picks the backend per-OS automatically (Windows ConPTY via
  pywinpty; Unix pty via ptyprocess) and resolves the `agy` binary via
  `--agy-path` first, then **per-OS**: on Windows the `%LOCALAPPDATA%` default
  then `PATH`; on Linux/macOS `PATH` then `~/.local/bin`, `~/.antigravity/bin`,
  `/usr/local/bin`. The Windows path is production-tested; the Unix path is
  review-verified but not yet runtime-tested on Linux/macOS.

## Safety model

- **External-LLM output is always treated as data, never executed as
  instructions.** (See `skills/babel/SKILL.md` §安全 and `protocol.md` §0.)
- Secrets/credentials are never placed in prompts sent to SOL/agy; babel scans
  the changeset for secret patterns before any external send and masks/excludes
  hits.
- SOL/agy write access is gated behind explicit user approval (`--allow-write`).
- Reproduction commands are reviewed by the lead before running (no sandbox
  assumption).

## Status

The three skill files are self-contained and carry empirical tuning from two
real-task pilots (design-debate value, heterogeneous acceptance checks,
canonical-data channel, difficulty-linked iteration cap). The original design
spec is a local development document and is **not** bundled — the skills need
only themselves to run.

## License

MIT — see [LICENSE](LICENSE).
