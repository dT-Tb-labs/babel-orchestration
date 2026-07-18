# babel — advanced / edge appendix

Rules that are real but fire rarely: multi-round state machinery (stateless-CLI
re-review across many rounds), the stuck-diagnosis playbook, cost-tier details,
and long code templates. The core files (`SKILL.md`, `protocol.md`,
`patterns.md`) point here so they stay minimal. Read this only for **L
multi-round tasks** or when a core pointer sends you here.

---

## A1. Multi-round state machinery (stateless external CLIs)

Needed only when a task runs many acceptance rounds and re-invokes SOL/agy, which
keep no memory between calls. Single/low-round tasks (most S/M) skip all of this —
the blackboard `state.json` round counter + `rejected` list is enough.

- **cursor** = a lead-recorded snapshot (file list + per-file hash or mtime+size).
  **delta** = the real file diff vs the previous snapshot (commit-independent).
- **round delta send** (protocol §6 origin): on the next call to a stateless CLI,
  send `diff(last_seen, current)` plus the unresolved finding lines, the rejected
  fingerprints, and their rejection reasons. Never send an ID alone — a stateless
  peer lacks the context and will re-raise or ask back.
- **rejected-fingerprint expiry**: a rejected entry keeps its record-time cursor.
  If a file containing the fingerprint's symbol changes, that rejection lapses and
  re-reporting is allowed again.
- **lead delta-read**: the lead greps only new ID lines instead of re-reading full
  result files.
- **global finding IDs**: on merge the lead assigns `sol-F1` / `agy-F1` / `wf-F1`
  (or a renumber); later matching, VerdictPackets, and deltas use the global ID.
- **VerdictPacket**: `{id:str, verdict:confirmed|refuted, reason:str}` —
  e.g. `{"id":"sol-F1","verdict":"confirmed","reason":"repro fails without patch, passes with patch"}`.
  Only needed when verdicts are exchanged across rounds; single-round merges verify inline.

## A2. sequential-switching (Phase 2 stuck playbook)

Fires when the **same issue (same file/symbol) fails a fix twice in a row**. (No
pilot has hit this yet — kept for completeness.)

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
   python3.13 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 180
   ```
   Bash `timeout: 200000`.
5. If agy misses too, the lead does one max-depth final rethink (ultrathink) —
   line up attempt 1 / attempt 2 / SOL / agy diagnoses and hunt the contradiction —
   before escalating to the user gate.

## A3. Milestone checkpoint (build-debug, optional)

For multi-milestone tasks, verify each milestone before the next. Skip entirely
when the milestone diff equals the whole final changeset (small task → fold into
the single Phase 3 acceptance call; avoids double-firing the same target).

```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier quick --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/checkpoint-r<N>.json. Read that file and the referenced diff. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Fix C/H before the next milestone; record M/L for the final acceptance pass.

## A4. Dynamic arbiter selection

When systems disagree and the difference survives grounding, the lead may
delegate arbitration to the domain-strongest model instead of deciding itself:
algorithmic/math → SOL, broad-knowledge/API-spec → agy, code-design/context → lead.
Send the arbiter **only the differences** (never the agreed parts).

## A5. completeness critic (L acceptance)

A final agent asking one fixed question: "what dimension is uncovered, what claim
unverified, what file unread?" Anything it surfaces seeds the next round. L-only.

## A6. Claude adversarial Workflow — full template

The dimension-split acceptance Workflow (Sonnet find → Opus adversarial verify).
L-only; M uses plain Agent-parallel review without the Opus verify stage.

```javascript
export const meta = {
  name: 'babel-acceptance-review',
  description: '検収ゲート: 次元別並列レビュー + 敵対的検証',
  phases: [
    { title: 'Review', detail: '4次元並列 (Sonnet effort low)' },
    { title: 'Verify', detail: '各findingをOpusが敵対的検証 (effort high)' },
  ],
}

const CHANGESET = '<changeset diffファイルパス or ファイルリスト>'
const CONTEXT = `対象: ${CHANGESET}。protocol.md の finding-jsonl 形式で報告せよ。severity(C/H/M/L)・file・line・claim・evidence(15-30tok)必須。憶測・スタイル好みは除外。`

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
  { key: 'correctness', prompt: `${CONTEXT}\n\n次元: correctness。ロジック誤り・境界値・型不整合を探せ。` },
  { key: 'security', prompt: `${CONTEXT}\n\n次元: security。injection・認証・機密露出を探せ。` },
  { key: 'edge-cases', prompt: `${CONTEXT}\n\n次元: edge-cases。null/空/並行/リトライ時の破綻を探せ。` },
  { key: 'spec-compliance', prompt: `${CONTEXT}\n\n次元: spec準拠。spec.md節ID参照で乖離を指摘せよ。` },
]

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDING_SCHEMA, model: 'sonnet', effort: 'low' }),
  (res, d) => {
    if (!res || !res.findings.length) return []
    return parallel(res.findings.map(f => () =>
      agent(`${CONTEXT}\n\n敵対的検証。反証するつもりでコードを読み、実際に成立するか判定せよ。\n所見(${d.key}): [${f.severity}] ${f.file}:${f.line} ${f.claim}\n根拠: ${f.evidence}`, {
        label: `verify:${d.key}:${f.file}:${f.line}`, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'opus', effort: 'high',
      }).then(v => ({ ...f, dimension: d.key, verdict: v }))
    ))
  }
)
const all = results.filter(Boolean).flat().filter(Boolean)
const confirmed = all.filter(f => f.verdict && f.verdict.real)
log(`所見 ${all.length} 件中 ${confirmed.length} 件が検証を通過`)
return { confirmed, rejectedCount: all.length - confirmed.length }
```
Workflow内のschema出力はリードがマージ時に finding-jsonl＋グローバルID へ正規化する。Workflowツールが無い環境は次元別レビューをAgent並列で代替。

## A7. Cost-tier details

- SOL tier: checkpoint=quick / design・acceptance=normal / stuck-diagnosis・critical-acceptance=deep.
  "critical acceptance" = L **and** security/irreversible task's acceptance SOL only.
- **deep cap = 2 per task** (ask the user past that).

## A8. Performance micro-optimizations

Low-stakes efficiency rules; ignore unless they bite.
- Verification batching: ~8-12 surviving findings per call; <8 remaining → one call.
- Log compression: send external only command + exit + failing line + log hash; expand on request.
- One concurrent call per external endpoint (SOL⊥agy parallel is fine).
- Workflow internals use `pipeline()` so dimension A's verify runs while dimension B still reviews.
- Instruction re-send: Claude subagents get a protocol pointer + stable prefix (prompt-cache hit); SOL gets the inline spec each time (re-reading saves nothing).
- Input-echo ban: findings cite `file:line`, not quoted hunks (unless the quote is the evidence).
