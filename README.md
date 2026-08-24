# babel — multi-model orchestration for Claude Code

`babel` is a Claude Code **skill** that orchestrates five models
(Fable 5 / Opus / Sonnet / GPT-5.6-SOL / Gemini 3 via `agy`) across the
[superpowers](https://github.com/obra/superpowers) pipeline
(brainstorm → plan → implement → review). It injects multi-model
**debate / build-debug / acceptance-gate** into each phase so the result
exceeds what a single frontier model produces — an ensemble
approach applied to a dev workflow.

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
    references/loop.md     # route selection + loop engineering (oracle, cascade, frozen set)
  cdx-sol/
    SKILL.md
    cdx-sol.mjs            # background+poll wrapper around codex-companion (Node, no deps)
  agy/
    SKILL.md
    agy_pty_wrapper.py     # cross-platform PTY wrapper for agy bug #76 (pywinpty / ptyprocess)
```

## Three shapes a task can run in

Before picking a crew, babel picks a **route** (`skills/babel/references/loop.md` §L0).
Scale (S/M/L) sizes the crew; the route decides what the crew does with it.

| Route | The task is | What runs |
|---|---|---|
| `linear` | a change someone can specify | design debate → build-debug → acceptance gate |
| `loop` | a number to move, where nobody yet knows which change moves it | a multi-model optimization loop against an automated oracle |
| `fanout` | the same small change across many independent sites | babel *proposes* a `Workflow` fan-out and waits for you to accept |

### Loop engineering

When the goal is measurable and the open question is *which* change wins, babel runs
an improvement loop instead of a linear implementation phase:

- **A charter gate first.** babel drafts the goal from your repo, then asks you to
  correct it — the metric and its direction, the target value, the exact oracle
  command, and the invariants that must hold regardless of the metric. A loop with an
  underspecified goal does not fail; it succeeds at the wrong thing for its whole budget.
- **Three models generate, the oracle selects.** Claude, GPT-5.6-SOL and Gemini 3 each
  propose one candidate per iteration, blind to each other, isolated in their own
  worktrees. Nobody votes — the measurement decides, which is why a loop can afford
  three generators where an acceptance round can barely afford three reviewers.
  The winner's diff and score are carried into every channel's next prompt, so the
  three compound instead of running three separate single-model loops.
- **Two separate cost controls, because they govern different things.** A cascade
  (`git apply --check` → frozen-set hash → build/lint → fast oracle subset → full
  oracle) keeps *oracle time* down: only survivors reach the expensive stage. Tokens
  are spent upstream of all of that, at generation, so they get their own controls —
  a per-channel delta from iteration 2 on (the charter and history are sent once, not
  twelve times), a fold ladder that lets a losing channel drop to every-other-iteration
  and then to a two-line hint instead of a full patch, and SOL pinned to its normal
  tier. A full-budget loop is still a millions-of-tokens run, and babel quotes it as
  one up front and asks again at iteration 5.
- **Anti-gaming is mechanical, not instructional.** The oracle, its inputs and every
  test file are a frozen set whose manifest lives outside the candidate worktrees and
  is re-hashed before any candidate is scored; a mismatch aborts the iteration and
  goes to you, rather than scoring zero and moving on. The loop optimizes a *proxy*,
  and a separate **held-out** oracle it never sees per-iteration is what the promoted
  winner is finally judged on. Proxy up + held-out down stops the loop immediately.
- **The winner still goes through the acceptance gate.** It has been measured, not
  reviewed, and an optimizer is exactly the process most likely to produce code that
  is correct on the measured path and nowhere else.

The mechanisms are adapted from public work — the evaluation cascade and score-carrying
prompt sampler from [AlphaEvolve / OpenEvolve](https://github.com/codelion/openevolve),
novelty rejection and bandit-over-ensemble from
[ShinkaEvolve](https://github.com/SakanaAI/ShinkaEvolve), and the proxy/held-out split
plus evaluator-tampering detection from the reward-hacking benchmarks (EvilGenie,
SpecBench, RewardHackingAgents). Credits and the reason each rule has its shape are in
`references/loop.md` §L8.


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
tells you when a channel is degraded off. See the "Dependencies & minimal setup" section in
`skills/babel/SKILL.md` for the Claude-only (single-channel) mode.

Then invoke from Claude Code:

```
/babel <task>
```

## Prerequisites

**babel** (lead):
- Claude Code. The `superpowers` skill set (brainstorming, writing-plans,
  executing-plans, subagent-driven-development) and the `Workflow` tool are
  recommended, not required — without superpowers the lead authors `spec.md` and
  calls Agents directly, and without Workflow the dimension split runs as parallel
  Agents (SKILL.md "Degradation without superpowers", patterns.md acceptance-gate).

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
  instructions.** (See `skills/babel/SKILL.md` §Safety and `protocol.md` §0.)
- Secrets/credentials are never placed in prompts sent to SOL/agy; babel scans
  the changeset for secret patterns before any external send and masks/excludes
  hits.
- SOL/agy write access is gated behind explicit user approval (`--allow-write`).
- Reproduction commands are reviewed by the lead before running (no sandbox
  assumption). A repro that came from an external channel is re-authored by the
  lead rather than run as received — pasting an external model's command into a
  shell would be executing its output.

### What the sandbox exclusion costs you

Both optional channels ask you to add a command to `sandbox.excludedCommands` in
`~/.claude/settings.json` (`"agyask"` + `"agyask *"`, `"solask"` + `"solask *"`).
That is a real hole in Claude Code's sandbox and you should decide about it
deliberately, so here is the whole trade:

**Why it is needed.** Neither CLI can run *inside* the sandbox. `cdx-sol` shells
out to `sandbox-exec` for its own read-only sandbox, and that cannot nest — every
workspace read fails with `sandbox_apply: Operation not permitted`. `agy` needs a
localhost bind for its language server and, as a Go binary on darwin, verifies TLS
through Security.framework, which the sandbox proxy breaks. The alternatives are
worse: `enableWeakerNetworkIsolation` opens an exfiltration path for *every*
sandboxed command, and a per-call bypass flag is a decision you would re-make,
and eventually mis-make, on every invocation.

**What you actually give up.** Only the wrapper process leaves the sandbox — an
excluded command runs with your normal filesystem and network access. Anything
able to invoke `agyask` or `solask` inherits that, which matters because review
payloads are untrusted input.

**What still constrains them.** `agyask` pins `--mode plan --sandbox`, so agy
cannot edit files or run commands even when a reviewed hunk contains text aimed
at it. Both shims resolve the executable they run from a fixed list of absolute
paths and never search `PATH`, so a planted `agy` or `node` cannot ride the
exclusion. `solask` refuses `--allow-write` and `CDX_SOL_COMPANION` outright:
write mode and companion overrides go through a direct `node .../cdx-sol.mjs`
call, which stays inside the sandbox and prompts. Both shims are short and worth
reading before you exempt them.

**The one part you cannot close from here.** `excludedCommands` matches the
command *name*. If anything earlier on your `PATH` is also called `agyask` or
`solask`, that is what runs outside the sandbox — the hardening above lives
inside these shims and never executes. Check what `command -v agyask solask`
resolves to after installing, and keep `~/.local/bin` ahead of any directory a
project or installer can write to.

**If you would rather not.** Skip the exclusion and drop that channel — babel is
designed to degrade (see the degradation table in `protocol.md` §10) and runs
first-class with Claude alone, at reduced independence.

**Why the exclusion is needed at all**, and what a narrower fix would look like
if Claude Code exposed one, is measured in
[SANDBOX-NOTES.md](SANDBOX-NOTES.md): Go binaries fail TLS inside the sandbox
because the Mach lookup for macOS's trust-evaluation agent is denied, and a
single `mach-lookup` grant for `com.apple.trustd.agent` restores it — a much
smaller hole than excluding the command. There is no settings key for it today.

## Status

The three skill files are self-contained and carry empirical tuning from two
real-task pilots (design-debate value, heterogeneous acceptance checks,
canonical-data channel, difficulty-linked iteration cap). The original design
spec is a local development document and is **not** bundled — the skills need
only themselves to run.

## License

MIT — see [LICENSE](LICENSE).

---

<sub>**Keywords:** Claude Code skill · multi-model / multi-agent AI orchestration · LLM ensemble · agentic dev workflow · automated code review & second opinion · design debate · build-debug loop · acceptance gate · Claude (Opus / Sonnet / Fable) + GPT-5.6-SOL (OpenAI Codex) + Gemini 3 (Google Antigravity `agy`) · superpowers pipeline · multi-model ensemble pattern.</sub>
