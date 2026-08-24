# babel — pilot log (empirical tuning record)

This is babel's **development diary**, not part of the runbook. The operational
rules it produced already live in `SKILL.md` / `references/protocol.md` /
`references/patterns.md`. Keep this out of the execution path; read it only to
understand *why* a rule exists or to plan the next tuning pass.

## Pilot 1 — M task (2026-07-17)
- debate-aggregation's multi-model value confirmed: an independent SOL design
  flagged a doc SoT-contract miss the lead alone might have wrongly discarded.
- Sonnet delegation cascade (offloading high-read work like caller-greps) worked
  as designed, preserving lead context.
- Blackboard (spec.md / state.json / results/) resume + write-once worked.
- agy died twice; root-caused: agy print/headless mode force-denies MCP-tool
  confirmation regardless of `permissions.allow` (agy-side behavior, not
  config-fixable). A global hook that nudges MCP-tool use can trigger it when the
  prompt hints at code exploration. Fix: append `Do not use any tools — answer
  directly from the text given above.` to every agy template (combined with the
  self-contained inline method it normally never fires). Verified by re-test.
- Added: checkpoint-skip condition, M-acceptance crew-size linked to diff size,
  the grounding-check duty for SOL findings on tiny diffs (SOL produced a
  false-positive about whitespace that did not exist).
- The design-difference user gate did not fire (grounding evidence resolved the
  difference) — confirmed correct gate behavior.
- ScheduleWakeup empty-polling for completion is wasted → rely on harness
  notification (protocol.md §8). agy's inline-only constraint adds lead-side
  summarization cost on large diffs — a still-unverified degradation area.

## Pilot 2 — L task (full crew, many parallel agents)
What worked: design-debate prevented adopting an inferior design (three
converging votes rejected a raw workaround for a more structural alternative);
heterogeneous acceptance caught different defect classes (SOL=code audit,
Opus=missing output, agy=independent clean verdict); the "judge verdict is also
data" principle let a false finding be rejected on grounding; a scratch
namespace + blackboard gave zero collisions.

Six changes fed back into the rules:
- Made the canonical-data channel a required TaskPacket field (`canon`): a data
  task's defect root cause was authoring from an image read instead of the
  primary source. (protocol.md §2, patterns.md debate step 0)
- Nested delegation is now declare-first: one channel silently spawned 5
  grand-children, hiding budget. (protocol.md §5)
- Wrote down the SoT one-way rule: a lead edit was nearly reverted by a stale
  blackboard re-merge. (protocol.md §5)
- Standard clause: re-ground before fixing an audit finding (a channel
  self-caught 2 false findings). (patterns.md acceptance merge step 4)
- Iteration cap is now difficulty-linked (one hard spot needed 7 rounds).
  (patterns.md termination)
- Per-wave token estimate is surfaced at the user gate (an expansion wave alone
  is millions of tokens). (Phase 0 approval gate)

## Pilot 3 — M task (2026-07-18, self-hosting: babel hardened babel to generality-A)
- 3-way design convergence (lead / SOL / agy) on the cross-platform PTY design;
  the single difference resolved on grounding, so the design-difference gate did
  not fire.
- 5-channel blind acceptance (Claude ×3 + agy + SOL); one HIGH (POSIX blocking
  read defeating `--timeout`) found independently by 2 channels — strong signal.
- 2 agy findings rejected on re-grounding (data-not-instruction): a claimed
  spawn-execvp gap (refuted by pre-spawn isfile check + ptyprocess error-pipe)
  and a pywinpty-bytes claim (refuted by a Windows runtime smoke test).
- SoT kept via sha256 hash sync between repo and live skill copies.
- Mostly single-round: the multi-round cursor/delta machinery did not fire —
  motivating its demotion to an L-only appendix.

## Pilot 4 — first `loop`-route run (2026-08-24, self-hosting: babel's loop route on babel's own context cost)

The first run of the `loop` route, and the reason `references/loop.md` stopped
being unvalidated prose. Deliberately small: S scale, **single-channel minimal
mode** (both external shims present, both backends absent — `cdx-sol`'s
companion missing, no `agy` binary), lead-as-generator per §L4 step 2's S case.

- **Task**: reduce the bytes a lead must read for an S-scale linear task.
  Oracle `skills/babel/tests/context-cost.py` (bytes as a stated proxy for
  tokens, so the number is exactly reproducible); guard
  `skills/babel/tests/rule-inventory.py`.
- **Result**: baseline 63,481 → 57,501 (**−9.4%**) on one candidate — splitting
  protocol §7 into what binds at every scale and a new §7b that only M/L read.
  Target was −20%, so by §L5 this is "budget stopped, best-so-far and the gap",
  not a success. The candidate was **not** promoted: see the reachability
  finding below.
- **What the route validated**: the charter gate, the baseline pair, the
  cascade ordering, worktree isolation, and the frozen-set gate all behaved as
  written. **What it could not**: three-vendor diversity, the externals'
  `BABEL_USAGE` reporting, and therefore the 2×-spend re-approval trigger.

Five things fed back into the rules, four of them defects the document could
not have surfaced without being run:

- **The frozen gate reported a setup mistake as tampering.** §L4 step 3
  isolates candidates in a git worktree; a worktree built from a commit does
  not contain an uncommitted oracle, so `frozen_check` saw the frozen set as
  modified on iteration 1. Added `frozen_precheck` (exit 2 = setup, distinct
  from 1 = violation) and the rule that the frozen set is committed before
  iteration 0. (§L2)
- **The frozen gate then fired on the oracle's own build artifacts** —
  `__pycache__/*.pyc` written beside the oracle by running it. A control that
  cries wolf on its own artifacts is a control that gets switched off. The
  manifest now drops git-ignored paths. (§L2)
- **...and the first fix had a second bug, also found by running it**: asking
  git about ignores in a plain *subdirectory* answers about the enclosing
  repository, and since `.babel/` is itself gitignored, a tree under it came
  back entirely ignored and the manifest was empty. The filter now applies
  only when the tree is a worktree top level. (§L2)
- **The drafted held-out was the proxy in a different mask.** A second byte
  count over a wider reading set moved the same way for the same reason. Added
  the charter-time test — *could a change that merely moves content move both?*
  — and the guard/held-out distinction: when the user's invariant is not
  measurable (here: "the output gets less accurate"), the honest configuration
  is a guard that bounds what was destroyed, reported in those words, never
  promoted to evidence that quality held. (§L3)
- **Reachability is the regression no numeric oracle sees.** The winning
  candidate cut 9.4% by *moving* half a section behind a scale gate, leaving it
  unreachable at a scale that needs it — with the rule-inventory guard green,
  because nothing was deleted. Every automated check passed on a candidate that
  had broken the skill. Moving candidates now get their routing read by hand.
  (§L5)

One more, kept as an observation rather than a rule: the three candidate lines
of attack this task admitted were **complements, not substitutes** — scoping
protocol §7, scoping SKILL.md, and compressing prose all add up rather than
competing. §L4's winner-takes-one selection discards the others by
construction. Whether that is a real limit of the route or an artifact of a
docs-compression task needs a second loop pilot on code before it becomes a
rule.

The charter gate earned its slot: the answer to the negative question ("what
would make you say this hit its number and still wasn't worth running?") was
*"if the output gets less accurate"*, which is exactly the invariant the byte
oracle cannot measure — and that one sentence is what produced the §L3 fix
above.

---

The original design-rationale spec is a local development document, not bundled.
The three skill files are self-contained and need only themselves to run.
