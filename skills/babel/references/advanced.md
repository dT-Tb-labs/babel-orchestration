# babel — advanced / edge appendix

Rarely-fired rules: stateless-CLI multi-round state, stuck diagnosis, cost tiers,
and long templates. Read only for **L multi-round tasks** or when `SKILL.md`,
`protocol.md`, or `patterns.md` points here.

---

## A1. Multi-round state machinery (stateless external CLIs)

Needed only when a task runs many acceptance rounds and re-invokes SOL/agy, which
keep no memory between calls. Single/low-round tasks (most S/M) skip this — the
blackboard `state.json` round counter + `rejected` list suffices.

- **cursor** = a lead-recorded snapshot (file list + per-file hash or mtime+size).
  **delta** = the file diff vs the previous snapshot (commit-independent). The exact
  JSON — `cursors.<channel>.{last_seen,snapshot}`, and `rejected[].{reason,cursor}` —
  is defined in `protocol.md` §5; single-round tasks already write that shape.
- **round delta send** (protocol §6 origin): on the next call to a stateless CLI,
  send `diff(last_seen, current)` plus the unresolved finding lines, rejected
  fingerprints, and their rejection reasons. Never send an ID alone — a stateless
  peer lacks context and will re-raise or ask back.
- **rejected-fingerprint expiry**: a rejected entry keeps its record-time cursor.
  If a file holding the fingerprint's symbol changes, that rejection lapses and
  re-reporting is allowed.
- **lead delta-read**: grep only new ID lines instead of re-reading full result files.
- **global finding IDs**: on merge the lead assigns `sol-F1` / `agy-F1` / `wf-F1`
  (or renumbers); later matching, VerdictPackets, and deltas use the global ID.
- **VerdictPacket**: `{id:str, verdict:confirmed|refuted, reason:str}` —
  e.g. `{"id":"sol-F1","verdict":"confirmed","reason":"repro fails without patch, passes with patch"}`.
  Only needed when verdicts cross rounds; single-round merges verify inline.

## A2. sequential-switching (Phase 2 stuck playbook)

Fires when the **same issue (same file/symbol) fails a fix twice in a row**. (No
pilot has hit this yet.)

1. Map the context to a TaskPacket: `goal="diagnose: <1-line symptom>"`,
   `files=[target]`, `criteria=["root cause","fix"]`,
   `constraints=["attempt 1: <summary+result>","attempt 2: <summary+result>","repro: <cmd>"]`,
   `out_schema=` the diagnosis JSON below.
2. Write it to `.babel/<task>/inbox/stuck-<n>.json` (argv-avoidance, protocol §3).
3. Hand to SOL deep:
   ```bash
   node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier deep --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/stuck-<n>.json. 2 consecutive fix attempts failed on the same issue. Diagnose root cause. Output diagnosis JSON only: {diagnosis:str, proposed_fix:str, confidence:high|med|low}. Example: {\"diagnosis\":\"race between timer and callback\",\"proposed_fix\":\"guard with generation counter\",\"confidence\":\"high\"}. No prose."
   ```
   Bash `timeout: 600000` (deep runs 5-6 min). **deep cap = 2 per task** (ask the user past that).
4. If SOL's diagnosis doesn't resolve it, switch to agy (inline the same context —
   symptom, both attempts, target hunk — since agy can't read fs):
   ```bash
   PROMPT=$(cat <<'EOF'
   TaskPacket: {"goal":"diagnose: <symptom>","files":[{"path":"<file>"}],"inputs":[],"criteria":["root cause","fix"],"constraints":["attempt 1: <...>","attempt 2: <...>","repro: <cmd>"],"out_schema":"diagnosis"}
   2 consecutive fix attempts failed. Target hunk: <inline the code hunk>
   Output diagnosis JSON only: {diagnosis:str, proposed_fix:str, confidence:high|med|low}. No prose. Do not use any tools — answer directly from the text given above.
   EOF
   )
   AGY_PRINT_TIMEOUT=180s agyask "$PROMPT"
   ```
   Bash `timeout: 200000`.
5. If agy misses too, the lead does one max-depth rethink (ultrathink) — line up
   attempt 1 / attempt 2 / SOL / agy diagnoses and hunt the contradiction — before
   escalating to the user gate.

## A3. Milestone checkpoint (build-debug, optional)

For multi-milestone tasks, verify each milestone before the next. Skip when the
milestone diff equals the whole final changeset — fold it into the single Phase 3
acceptance call to avoid double-firing the same target.

First write both files the command below reads — the milestone diff, and the
packet pointing at it:

```bash
git diff <previous milestone ref> > .babel/<task>/inbox/checkpoint-r<N>.diff
```
```json
{"goal":"spec-drift and bug check at milestone <N>",
 "files":[{"path":".babel/<task>/inbox/checkpoint-r<N>.diff"}],
 "inputs":[".babel/<task>/spec.md"],
 "criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
```
written to `.babel/<task>/inbox/checkpoint-r<N>.json`, then:

```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier quick --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/checkpoint-r<N>.json. Read that file and the referenced diff. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Fix C/H before the next milestone; record M/L for the final acceptance pass.

## A4. Dynamic arbiter selection

When systems disagree and the difference survives grounding, the lead may delegate
arbitration to the domain-strongest model instead of deciding itself: algorithmic/math
→ SOL, broad-knowledge/API-spec → agy, code-design/context → lead. Send the arbiter
**only the differences**, never the agreed parts.

## A5. completeness critic (L acceptance)

A final agent asking one fixed question: "what dimension is uncovered, what claim
unverified, what file unread?" What it surfaces seeds the next round. L-only, and
it runs after **every** candidate clean round — including a clean round 1, where
an uncovered dimension is the likeliest explanation for finding nothing.

Run it as one Opus agent (`effort: 'high'`), given the changeset diff path, the
spec path, the round's merged findings, and the list of dimensions/reviewers that
actually ran:

```
schema: {gaps: [{kind: 'dimension'|'claim'|'file', what: str, why_it_matters: str}]}
```

**Empty means `gaps: []`.** A critic that returns prose, or gaps whose `what`
names something already covered by a reviewer that ran, does not count as empty —
re-request once (protocol.md §7 schema gate), and on a second failure treat the
round as non-converged and run another round. Non-empty gaps become the next
round's dimensions.

## A6. Claude adversarial Workflow — full template

Dimension-split acceptance Workflow (Sonnet find → Opus adversarial verify). L-only;
M uses plain Agent-parallel review without the Opus verify stage.

```javascript
export const meta = {
  name: 'babel-acceptance-review',
  description: 'acceptance gate: dimension-split parallel review + adversarial verification',
  phases: [
    { title: 'Review', detail: '4-dimension parallel (Sonnet effort low)' },
    { title: 'Verify', detail: 'Opus adversarially verifies each finding (effort high)' },
  ],
}

const CHANGESET = '.babel/<task>/inbox/changeset.diff'
const SPEC = '.babel/<task>/spec.md'
const MAX_FINDINGS = 20   // per dimension group; each one spawns an Opus verifier
const CONTEXT = `TaskPacket: {"goal":"acceptance review of the changeset","files":[{"path":"${CHANGESET}"},{"path":"${SPEC}"}],"inputs":["${CHANGESET}","${SPEC}"],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Read those two paths — they are your only inputs (protocol.md §2 access list). Report in protocol.md's finding-jsonl format: severity(C/H/M/L), file, line, claim, evidence(~10-25 words) required. Exclude speculation and style preferences. Report at most ${MAX_FINDINGS} findings, highest severity first.`

const FINDING_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      maxItems: MAX_FINDINGS,
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['C', 'H', 'M', 'L'] },
          file: { type: 'string' },
          line: { type: 'integer' },
          claim: { type: 'string' },
          evidence: { type: 'string' },
        },
        required: ['severity', 'file', 'line', 'claim', 'evidence'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: { real: { type: 'boolean' }, reason: { type: 'string' } },
  required: ['real', 'reason'],
}

const LENS = {
  correctness: 'logic errors, boundary values, type mismatches',
  security: 'injection, authentication, secret exposure',
  'edge-cases': 'breakage under null/empty/concurrency/retry',
  'spec-compliance': 'divergences from the spec, cited by section ID',
}
// Grouping comes from the changeset size (patterns.md acceptance-gate step 1):
// <50 lines -> one group of all four; 50-200 -> two groups; >200 -> three.
const GROUPS = [['correctness', 'security', 'edge-cases', 'spec-compliance']]
const DIMENSIONS = GROUPS.map(keys => ({
  key: keys.join('+'),
  prompt: `${CONTEXT}\n\ndimensions: ${keys.map(k => `${k} (${LENS[k]})`).join('; ')}`,
}))

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDING_SCHEMA, model: 'sonnet', effort: 'low' }),
  (res, d) => {
    if (!res || !res.findings.length) return []
    if (res.findings.length >= MAX_FINDINGS) log(`${d.key}: hit the ${MAX_FINDINGS}-finding cap — lower-ranked findings were dropped`)
    return parallel(res.findings.map(f => () =>
      agent(`${CONTEXT}\n\nAdversarial verification. Read the code intending to refute it, and judge whether it actually holds.\nFinding(${d.key}): [${f.severity}] ${f.file}:${f.line} ${f.claim}\nEvidence: ${f.evidence}`, {
        label: `verify:${d.key}:${f.file}:${f.line}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'high',
      }).then(v => ({ ...f, dimension: d.key, verdict: v }))
    ))
  }
)
const all = results.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter(f => f.verdict && f.verdict.real)
log(`${confirmed.length} of ${all.length} findings passed verification`)
return { confirmed, rejectedCount: all.length - confirmed.length }
```
At merge time the lead normalizes the Workflow's schema output into finding-jsonl + global ID. Without the Workflow tool, substitute Agent-parallel review for the dimension-split review.

**Declare the verifier ceiling in the crew proposal**: worst case is `GROUPS.length × MAX_FINDINGS` Opus verifiers (20 with one group, 60 with three). The cap is what keeps one verbose reviewer from turning an approved 5-member crew into dozens of agents, so state the number the user is approving.

## A7. Cost-tier details

- SOL tier: checkpoint=quick / design/acceptance=normal / stuck-diagnosis/critical-acceptance=deep.
  "critical acceptance" = L **and** security/irreversible task's acceptance SOL only.
- **deep cap = 2 per task** (ask the user past that).

## A8. Performance micro-optimizations

Low-stakes efficiency rules; ignore unless they bite.
- Verification batching: ~8-12 surviving findings per call; <8 remaining → one call.
- Log compression: send external only command + exit + failing line + log hash; expand on request.
- One concurrent call per external endpoint (SOL⊥agy parallel is fine).
- Workflow internals use `pipeline()` so dimension A's verify runs while dimension B still reviews.
- Instruction re-send: Claude subagents get a protocol pointer + stable prefix (prompt-cache hit); SOL gets the inline spec each time.
- Input-echo ban: findings cite `file:line`, not quoted hunks (unless the quote is the evidence).

## A9. Within-task channel adaptation (online, L multi-round only)

Within one task, autonomously adjust channel composition with **no human gate**. This learning is **ephemeral**: discard `channel_scoreboard` with `.babel/<task>/` and never write it into SKILL.md/protocol.md. Unlike persistent offline convention evolution, this prevents self-reference lock, N=1 overfitting, and permanent external-output injection. **Do not mix the two**; offline evolution requires human approval.

**Firing condition**: **L and multi-round** (≥3 rounds expected) only. S/M finish before learning ramps up, so keep the fixed crew composition (the bandit becomes noise).

**Sole signal — grounded outcomes**: use only `confirmed`/`refuted` from `state.json.channel_scoreboard` (protocol.md §5), grounded in code/primary sources. Never use subjective lead/LLM evaluation (`protocol.md` §7 invariant).

**Adjustment rule (multi-armed bandit, reward = confirmed/token)**: after each round's merge, read the scoreboard to decide the next round's crew composition. Every field this rule needs — per-round `confirmed`/`refuted`, `tokens`, `classes` — is in the `channel_scoreboard` entry the lead appends at merge (protocol.md §5). Early = exploration (fire all channels), late = exploitation.
- **Drop**: sum the last 2 round entries for a channel; `confirmed=0` and `refuted≥2` → remove it from the next round. Do not pay tokens for only false positives. Applies within the current task only; all channels revive next task.
- **Exploitation (routing bias)**: read `classes` across rounds; if confirmed findings of one defect class concentrate in a channel, make it the priority re-run target of change-impact routing (protocol.md §9). Ties break toward the channel with the higher `confirmed/tokens` ratio, then toward the cheaper channel.
- **Stretch/shrink**: read with the convergence trend (patterns.md termination condition) — if new C/H keeps declining and all channels skew `refuted`, treat as early convergence and fold the crew composition. While high `confirmed` continues, extend without consuming the difficulty-linked cap.

**Grounding-cost discipline** (protocol.md §7): ground only differing or single-lineage findings, and ground multiple-lineage agreements first — but agreement alone never writes `confirmed`. Ungrounded findings stay out of the scoreboard entirely, so the bandit only ever reads reality-checked labels.

**Observing ensemble value (byproduct)**: the scoreboard records for free which channel earned grounding-confirmed findings. If on some task `confirmed` comes almost entirely from one channel (e.g. Claude introspection), that is direct evidence that — **for that task** — the other channels could not earn their tokens (ablation by observation). This describes one task and is not grounds for a convention change; it revises the crew-composition table only after cross-task offline analysis + a human gate.
