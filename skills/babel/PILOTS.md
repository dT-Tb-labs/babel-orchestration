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

---

The original design-rationale spec is a local development document, not bundled.
The three skill files are self-contained and need only themselves to run.
