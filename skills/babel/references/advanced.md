# babel — advanced / edge appendix

Real but rarely-fired rules: multi-round state machinery (stateless-CLI re-review
across many rounds), the stuck-diagnosis playbook, cost-tier details, and long
code templates. `SKILL.md`, `protocol.md`, and `patterns.md` point here to stay
minimal. Read only for **L multi-round tasks** or when a core pointer sends you here.

---

## A1. Multi-round state machinery (stateless external CLIs)

Needed only when a task runs many acceptance rounds and re-invokes SOL/agy, which
keep no memory between calls. Single/low-round tasks (most S/M) skip this — the
blackboard `state.json` round counter + `rejected` list suffices.

- **cursor** = a lead-recorded snapshot (file list + per-file hash or mtime+size).
  **delta** = the file diff vs the previous snapshot (commit-independent).
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
   python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 180
   ```
   Bash `timeout: 200000`.
5. If agy misses too, the lead does one max-depth rethink (ultrathink) — line up
   attempt 1 / attempt 2 / SOL / agy diagnoses and hunt the contradiction — before
   escalating to the user gate.

## A3. Milestone checkpoint (build-debug, optional)

For multi-milestone tasks, verify each milestone before the next. Skip when the
milestone diff equals the whole final changeset — fold it into the single Phase 3
acceptance call to avoid double-firing the same target.

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
unverified, what file unread?" What it surfaces seeds the next round. L-only.

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

const CHANGESET = '<changeset diff file path or file list>'
const CONTEXT = `Target: ${CHANGESET}. Report in protocol.md's finding-jsonl format. severity(C/H/M/L), file, line, claim, evidence(15-30tok) required. Exclude speculation and style preferences.`

const FINDING_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
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

const DIMENSIONS = [
  { key: 'correctness', prompt: `${CONTEXT}\n\ndimension: correctness. Hunt for logic errors, boundary values, type mismatches.` },
  { key: 'security', prompt: `${CONTEXT}\n\ndimension: security. Hunt for injection, authentication, secret exposure.` },
  { key: 'edge-cases', prompt: `${CONTEXT}\n\ndimension: edge-cases. Hunt for breakage under null/empty/concurrency/retry.` },
  { key: 'spec-compliance', prompt: `${CONTEXT}\n\ndimension: spec compliance. Point out divergences with spec.md section-ID references.` },
]

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDING_SCHEMA, model: 'sonnet', effort: 'low' }),
  (res, d) => {
    if (!res || !res.findings.length) return []
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

Within a single task, autonomously adjust the channel crew composition live. **Fully autonomous, no human gate** — safe because it is **ephemeral**: learning is discarded at task end and `channel_scoreboard` shares the lifetime of `.babel/<task>/`. This is the decisive difference from offline convention evolution (persistent, human approval mandatory): kill cross-task persistence and the dangerous failure modes (self-reference lock, N=1 overfitting, permanent injection of external output) vanish, leaving only the autonomy. **Do not mix the two** — never write the scoreboard back into SKILL.md/protocol.md.

**Firing condition**: **L and multi-round** (≥3 rounds expected) only. S/M finish before learning ramps up, so keep the fixed crew composition (the bandit becomes noise).

**Sole driving signal — grounded outcomes**: judge only by `confirmed`/`refuted` in `state.json.channel_scoreboard` (protocol.md §5). **Never drive by the lead's/LLM's subjective evaluation ("this channel seems good")** — the invariant of protocol.md §7. Both labels are grounded in real code / primary sources, not opinions.

**Adjustment rule (multi-armed bandit, reward = confirmed/token)**: after each round's merge, read the scoreboard to decide the next round's crew composition. Early = exploration (fire all channels), late = exploitation.
- **Drop**: a channel with `confirmed=0` and `refuted≥2` over the last 2 rounds → remove from the next round. Do not pay tokens for only false positives. Applies within the current task only; all channels revive next task.
- **Exploitation (routing bias)**: if `confirmed` for a defect class concentrates in one channel, make it the priority re-run target of change-impact routing (protocol.md §9).
- **Stretch/shrink**: read with the convergence trend (patterns.md termination condition) — if new C/H keeps declining and all channels skew `refuted`, treat as early convergence and fold the crew composition. While high `confirmed` continues, extend without consuming the difficulty-linked cap.

**Grounding-cost discipline**: grounding costs the lead's context + tokens. Do not ground every find on every channel each round — extending protocol.md §7 "arbitrate only the differences," ground only findings that differ or are single-lineage, and record the result. Agreed findings (multiple lineages concur) count as `confirmed`.

**Observing ensemble value (byproduct)**: the scoreboard records for free which channel earned grounding-confirmed findings. If on some task `confirmed` comes almost entirely from one channel (e.g. Claude introspection), that is direct evidence that — **for that task** — the other channels could not earn their tokens (ablation by observation). This describes one task and is not grounds for a convention change; it revises the crew-composition table only after cross-task offline analysis + a human gate.
