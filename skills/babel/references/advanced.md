# babel — advanced / edge appendix

Rarely-fired rules: stateless-CLI multi-round state, stuck diagnosis, cost tiers,
and long templates. Read only for **L multi-round tasks** or when `SKILL.md`,
`protocol.md`, or `patterns.md` points here.

---

## A1. Multi-round state machinery (stateless external CLIs)

Needed only when a task runs many acceptance rounds and re-invokes SOL/agy, which
keep no memory between calls. Single/low-round tasks (most S/M) skip this — the
blackboard `state.json` round counter + `rejected` list suffices.

- **cursor** = a lead-recorded snapshot (file list + per-file content hash and byte
  count — not mtime, which moves without the content moving).
  **delta** = the file diff vs the previous snapshot (commit-independent). The exact
  JSON — `cursors.<channel>.{last_seen,snapshot}`, and `rejected[].{reason,cursor}` —
  is defined in `protocol.md` §5; single-round tasks already write that shape.
- **round delta send** (protocol §6 origin): on the next call to a stateless CLI,
  send `diff(snapshot, current)` plus the unresolved finding lines, rejected
  fingerprints, and their rejection reasons. Diff the **snapshot**, not
  `last_seen` — `last_seen` is a round number, so it has no content to diff. The
  snapshot names which paths moved; the hunks come from `.babel/<task>/snap-r<N>/`,
  which holds a verbatim copy of each changeset file as that round dispatched it,
  under its repo-relative path. The delta is then per moved path
  `diff -u --strip-trailing-cr .babel/<task>/snap-r<last_seen>/<p> <p>`, with
  `/dev/null` standing in for whichever side is absent when a path was added or
  deleted since that round — real source hunks. A channel with no `last_seen` at
  all — never dispatched, or failed on its first call so the pair was never
  committed — has no snapshot to diff against and gets the **full changeset**, not
  a delta. Two things
  not to do: sending `changeset-r<last_seen>.diff` itself re-reviews the version the
  channel already saw and omits the repair entirely, and diffing two patch files
  against each other yields a diff-of-diffs, which is meta-text, not the source
  hunks protocol.md §5 asks for. Never send an ID alone — a stateless
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
   [ "$(printf '%s' "$PROMPT" | wc -c)" -lt 32768 ] || { echo 'over the 32 KB cap — split or drop agy (protocol.md §3)' >&2; exit 1; }
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
round's dimensions. **The 8-round ceiling still binds**: at the ceiling there is
no "another round" to run, so an unresolved critic goes to the user gate as
residual risk (patterns.md termination condition) — the critic is a convergence
test, never a licence to extend past the cap.

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

// Round 1 reviews the changeset; round ≥2 reviews that round's delta instead
// (SKILL.md Cost discipline) — repoint this before re-running, or every later
// round re-reads the whole changeset it already reviewed.
// round ≥2: repoint at this channel's own delta — '.babel/<task>/inbox/delta-r<N>.diff'
// when the Claude track's last_seen is current, or its '-claude' variant when it lags
// (patterns.md acceptance-gate). A channel with no last_seen keeps the full changeset.
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

// One call verifies a batch, not one finding (§A8). `i` keys the verdict back to
// its finding — without it a short or reordered reply silently mislabels findings.
const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: { i: { type: 'integer' }, real: { type: 'boolean' }, reason: { type: 'string' } },
        required: ['i', 'real', 'reason'],
      },
    },
  },
  required: ['verdicts'],
}
const BATCH = 10   // findings per verifier call (§A8: 8-12)
const chunk = (xs, n) => xs.reduce((a, x, i) => (i % n ? a[a.length - 1].push(x) : a.push([x]), a), [])

const LENS = {
  correctness: 'logic errors, boundary values, type mismatches',
  security: 'injection, authentication, secret exposure',
  'edge-cases': 'breakage under null/empty/concurrency/retry',
  'spec-compliance': 'divergences from the spec, cited by section ID',
}
// Grouping comes from the measured changeset size (patterns.md acceptance-gate
// step 1). Set GROUPS from the bracket that matches — shipping the template
// unedited would review a 900-line changeset with a single agent.
const GROUPS_BY_SIZE = {
  small: [['correctness', 'security', 'edge-cases', 'spec-compliance']],      // <50 lines
  medium: [['correctness', 'edge-cases'], ['security', 'spec-compliance']],   // 50-200
  large: [['correctness'], ['security'], ['edge-cases', 'spec-compliance']],  // >200
}
const GROUPS = GROUPS_BY_SIZE.small   // <- replace `.small` with the measured bracket
const DIMENSIONS = GROUPS.map(keys => ({
  key: keys.join('+'),
  prompt: `${CONTEXT}\n\ndimensions: ${keys.map(k => `${k} (${LENS[k]})`).join('; ')}`,
}))

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDING_SCHEMA, model: 'sonnet', effort: 'low' }),
  (res, d) => {
    // A dead reviewer is a channel failure, not a clean dimension. Returning []
    // here would let the round read as converged because nobody looked
    // (protocol.md §7 schema gate, §10 degradation).
    if (!res) return [{ dimension: d.key, channelFailure: true }]
    if (!res.findings.length) return []
    if (res.findings.length >= MAX_FINDINGS) log(`${d.key}: hit the ${MAX_FINDINGS}-finding cap — lower-ranked findings were dropped`)
    // Verify C/H only (protocol.md §4). M/L are reported to the user as-is; paying
    // an adversarial verifier for findings nobody will act on is the single largest
    // avoidable cost in this template.
    const toVerify = res.findings.filter(f => f.severity === 'C' || f.severity === 'H')
    const passthrough = res.findings.filter(f => f.severity !== 'C' && f.severity !== 'H')
      .map(f => ({ ...f, dimension: d.key, verdict: null }))
    if (passthrough.length) log(`${d.key}: ${passthrough.length} M/L findings pass through unverified (protocol.md §4)`)
    if (!toVerify.length) return passthrough
    return parallel(chunk(toVerify, BATCH).map((batch, b) => () =>
      // Narrow access list on purpose: the verifier opens the cited files only.
      // Re-sending the reviewer's full CONTEXT here makes every verifier re-read
      // the whole input set, which is what turns one round into millions of tokens.
      agent(`Adversarial verification against ${CHANGESET} and ${SPEC}. Open only the files and lines the findings cite — nothing else.\nTry to REFUTE each finding. Default to real=false unless following the runbook literally would produce wrong behaviour. Return one verdict per finding, keyed by its index i.\n${batch.map((f, i) => `[${i}] ${f.severity} ${f.file}:${f.line} — ${f.claim} | evidence: ${f.evidence}`).join('\n')}`, {
        label: `verify:${d.key}:b${b}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'high',
      }).then(v => {
        // A dead agent returns null and a short reply returns fewer verdicts than
        // findings; either way the unmatched findings must stay visibly unresolved
        // rather than silently inheriting some other finding's verdict.
        // Drop malformed entries rather than indexing into them: a null entry
        // throws on x.i, and a truthy non-boolean `real` would silently confirm.
        const vs = v && Array.isArray(v.verdicts)
          ? v.verdicts.filter(x => x && typeof x.i === 'number' && typeof x.real === 'boolean')
          : []
        return batch.map((f, i) => ({ ...f, dimension: d.key, verdict: vs.find(x => x.i === i) || null }))
      })
    )).then(rs => rs.filter(Boolean).flat().concat(passthrough))
  }
)
const isCH = f => f.severity === 'C' || f.severity === 'H'
const out = results.filter(Boolean).flat().filter(Boolean)
const failedDimensions = out.filter(f => f.channelFailure).map(f => f.dimension)
const all = out.filter(f => !f.channelFailure)
const verified = all.filter(f => f.verdict)
const confirmed = verified.filter(f => f.verdict.real)
const unresolved = all.filter(f => !f.verdict && isCH(f))    // verifier never ruled on these
const unverified = all.filter(f => !f.verdict && !isCH(f))   // M/L, deliberately unverified
log(`${confirmed.length}/${verified.length} C/H confirmed; ${unresolved.length} C/H unresolved; ${unverified.length} M/L unverified; ${failedDimensions.length} dimension(s) failed`)
return { confirmed, rejectedCount: verified.length - confirmed.length, unresolved, unverified, failedDimensions }
```
A non-empty `failedDimensions` means that dimension was never reviewed — the round is not a candidate clean round no matter how few findings came back, and the dimension is re-dispatched or declared dropped to the user. A non-empty `unresolved` is a §7 schema-gate failure, not a clean result: re-request that batch once, and if it comes back short again treat the track as degraded for the round (protocol.md §10) rather than reporting those C/H as if nobody found them. At merge time the lead normalizes the Workflow's schema output into finding-jsonl + global ID. Without the Workflow tool, substitute Agent-parallel review for the dimension-split review.

**Declare the verifier ceiling in the crew proposal**: worst case is
`GROUPS.length × ceil(MAX_FINDINGS / BATCH)` Opus verifiers — 2 with one group, 6
with three, and only for C/H findings. State the number the user is approving.

Measured (this template's own hardening run, 3 acceptance rounds): the pre-batch
shape — one Opus verifier per finding at every severity, each re-sent the
reviewer's full CONTEXT — cost **2.12M subagent tokens for 3 confirmed findings**,
while SOL over the same rounds returned 25 confirmed for ~100k. Batching, the C/H
filter, and the narrow verifier access list target exactly that gap. If a Workflow
round's spend is not within an order of magnitude of the external channels', the
template has been edited back toward the expensive shape.

## A7. Cost-tier details

- SOL tier: checkpoint and S acceptance=quick / design and M/L acceptance=normal / stuck-diagnosis and critical acceptance=deep.
  "critical acceptance" = L **and** security/irreversible task's acceptance SOL only.
- **deep cap = 2 per task** (ask the user past that).

## A8. Performance micro-optimizations

Low-stakes efficiency rules; ignore unless they bite.
- Verification batching: ~8-12 surviving findings per call; <8 remaining → one call. This binds the Workflow template too (§A6) — one agent per finding is the single most expensive way to get the same verdicts, and it also breaks protocol.md §4 by verifying M/L nobody will act on.
- Verifier access list: findings + the paths they cite. Never re-send the reviewing agent's full input set; a verifier that re-reads the whole changeset costs as much as the reviewer that produced the finding.
- Round ≥2 reviewers receive the delta, not the changeset — Claude reviewers included, not just the stateless externals (§A1).
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
- **Fold on reward before dropping on failure**: the drop rule above needs
  `confirmed=0`, which a channel earning one finding per round never hits no matter
  what it costs. So also compare `confirmed/token` across channels each round and
  fold any channel an order of magnitude below the best to its cheapest useful form.
  The fold form is per channel: an **in-Claude track** drops to one dimension group,
  or to the completeness-critic slot; **SOL** drops one tier (deep→normal→quick) and
  its scope narrows to the paths the fix touched; **agy** receives only the delta
  hunks for those paths, or sits the round out. Sitting out is a one-round skip,
  not a fold state: the channel is dispatched again the following round, since a
  channel that never runs can never earn its way back. Folding never silently
  removes a channel — that is the drop rule's job, and it is reported either way.
  Folding is reversible within the task: a folded channel that still earns
  `confirmed` comes back to full width. A channel folded into the critic slot is
  the exception, since a critic emits `gaps`, never groundable findings — it
  restores on a non-empty `gaps` list instead. Keep `gaps` out of
  `channel_scoreboard`: it is a restoration signal, not a grounding label (§7). Measured on this skill's own hardening run,
  the gap between the best and worst channel was ~250× reward, with no round in
  which the drop rule fired.
- **Exploitation (routing bias)**: read `classes` across rounds; if confirmed findings of one defect class concentrate in a channel, make it the priority re-run target of change-impact routing (protocol.md §9). Ties break toward the channel with the higher `confirmed/tokens` ratio, then toward the cheaper channel.
- **Stretch/shrink**: read with the convergence trend (patterns.md termination condition) — if new C/H keeps declining and all channels skew `refuted`, treat as early convergence and fold the crew composition. While high `confirmed` continues, extend. Whether the round consumes budget is not this rule's call: `budget.rounds_consumed` has exactly one condition, "new C/H did not decrease" (protocol.md §5), and a high-`confirmed` round that still decreased new C/H leaves it untouched by that condition, not by this one. The 8-round hard ceiling on `round` still binds regardless — no scoreboard trend extends past it.

**Grounding-cost discipline** (protocol.md §7): every C/H is eligible and each is grounded once — what the rule bounds is order, agreements first, then differences, then single-lineage — but agreement alone never writes `confirmed`. Ungrounded findings stay out of the scoreboard entirely, so the bandit only ever reads reality-checked labels.

**Observing ensemble value (byproduct)**: the scoreboard records for free which channel earned grounding-confirmed findings. If on some task `confirmed` comes almost entirely from one channel (e.g. Claude introspection), that is direct evidence that — **for that task** — the other channels could not earn their tokens (ablation by observation). This describes one task and is not grounds for a convention change; it revises the crew-composition table only after cross-task offline analysis + a human gate.
