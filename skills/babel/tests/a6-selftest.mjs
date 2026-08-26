#!/usr/bin/env node
// Extracts A6's acceptance Workflow template from advanced.md and runs it against
// stubs. Like gate-selftest.sh and loop-selftest.sh, it never copies the block: a
// template that stops parsing, or stops rejecting what it exists to reject, fails
// here. A6 is the largest executable in this skill (~350 lines of real JavaScript
// that runs every L acceptance round). It was not untested: install.sh already
// parses the block and exercises `receiptFailure` on seven cases. What it did not
// reach is everything else — the args guard, the void-round throw, the reviewer
// brackets, verify routing, rejection handling and cap accounting — which is what
// this file adds. The receipt-gate cases overlap install.sh deliberately: that
// check runs where the repo may not exist, this one runs where it does.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dirname } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const DOC = join(HERE, '..', 'references', 'advanced.md')

// --- extract the fenced javascript block that defines the template -------------
function extractBlock() {
  const lines = readFileSync(DOC, 'utf8').split('\n')
  let inB = false, buf = []
  for (const line of lines) {
    if (!inB && line === '```javascript') { inB = true; buf = []; continue }
    if (inB && line === '```') {
      const src = buf.join('\n')
      if (src.includes("name: 'babel-acceptance-review'")) return src
      inB = false; continue
    }
    if (inB) buf.push(line)
  }
  throw new Error('A6 javascript block not found in ' + DOC)
}

const BLOCK = extractBlock()
for (const needle of ['export const meta', 'receiptFailure', 'GROUPS_BY_SIZE', 'return {']) {
  if (!BLOCK.includes(needle)) throw new Error(`extracted block is missing ${needle} — wrong block?`)
}

// The Workflow runtime wraps the script body in an async function and injects
// agent/parallel/pipeline/phase/log/args as globals. Reproduce exactly that, and
// nothing more: a harness that patches the block is testing the patch.
const DIR = mkdtempSync(join(tmpdir(), 'babel-a6-'))
function buildModule(stubSrc) {
  const src = `${stubSrc}\nexport const run = async () => {\n${BLOCK.replace('export const meta', 'const meta')}\n}\n`
  const p = join(DIR, `m${Math.abs(hash(stubSrc + BLOCK))}.mjs`)
  writeFileSync(p, src)
  return p
}
function hash(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) | 0; return h }

// --- stub factory ---------------------------------------------------------------
// calls[] records every agent() dispatch so the assertions can read the shape the
// template chose (how many dimension groups, which labels, which phase).
const STUB = (argsValue, agentImpl) => `
const calls = []
export const getCalls = () => calls
const args = ${JSON.stringify(argsValue)}
const log = () => {}
const phase = () => {}
const agent = async (prompt, opts = {}) => {
  calls.push({ prompt, ...opts })
  return (${agentImpl})(prompt, opts, calls.length - 1)
}
const parallel = async (thunks) => {
  const out = []
  for (const t of thunks) { try { out.push(await t()) } catch { out.push(null) } }
  return out
}
const pipeline = async (items, ...stages) => {
  const out = []
  for (let i = 0; i < items.length; i++) {
    let v = items[i]
    try { for (const s of stages) v = await s(v, items[i], i) } catch { v = null }
    out.push(v)
  }
  return out
}
`

const GOOD_ARGS = {
  diff: 'changeset.diff', spec: 'spec.md', diffLines: 100, round: 1,
  digest: 'deadbeef', receiptTokens: ['tok-a', 'tok-b'],
}
const receipt = (over = {}) => ({
  tokens: ['tok-a', 'tok-b'], paths: ['changeset.diff'], unread: [],
  dimensions: ['correctness', 'security', 'edge-cases', 'spec-compliance'], ...over,
})
// A reviewer that returns a clean, well-formed response covering whatever it was asked.
const CLEAN = `(prompt, opts) => ({ moreFindingsExist: false, findings: [], receipt: {
  tokens: ['tok-a','tok-b'], paths: ['changeset.diff'], unread: [],
  dimensions: ['correctness','security','edge-cases','spec-compliance'] } })`

let fails = 0
const ok = (cond, what) => { if (!cond) { console.log(`FAIL: ${what}`); fails++ } }

async function run(argsValue, agentImpl = CLEAN) {
  const mod = await import(buildModule(STUB(argsValue, agentImpl)))
  const result = await mod.run()
  return { result, calls: mod.getCalls() }
}
async function throws(argsValue, agentImpl = CLEAN) {
  try { await run(argsValue, agentImpl); return null } catch (e) { return e.message }
}

// --- args guard -----------------------------------------------------------------
ok(await throws({ ...GOOD_ARGS, diff: undefined }), 'missing diff must throw')
ok(await throws({ ...GOOD_ARGS, spec: undefined }), 'missing spec must throw')
ok(await throws({ ...GOOD_ARGS, digest: undefined }), 'missing digest must throw')
ok(await throws({ ...GOOD_ARGS, round: '1' }), 'non-numeric round must throw')
ok(await throws({ ...GOOD_ARGS, receiptTokens: ['only-one'] }), 'one receipt token must throw')
ok(await throws({ ...GOOD_ARGS, receiptTokens: undefined }), 'missing receiptTokens must throw')
// The header comment says args arrives as a JSON string on some harness paths and
// as an object on others, and that both were measured. If the normalisation is ever
// dropped, a correctly-formed call dies at 0 agents blaming the caller.
ok(!(await throws(JSON.stringify(GOOD_ARGS))), 'args as a JSON string must be accepted')

// --- void round -----------------------------------------------------------------
// diffLines 0 must NOT quietly take the small bracket and come back clean.
ok(await throws({ ...GOOD_ARGS, diffLines: 0 }), 'diffLines 0 must throw, not review')
ok(await throws({ ...GOOD_ARGS, diffLines: -5 }), 'negative diffLines must throw')

// --- reviewer bracket by diff size ----------------------------------------------
const groups = async (over) => (await run({ ...GOOD_ARGS, ...over })).calls
  .filter(c => c.phase === 'Review').length
ok(await groups({ diffLines: 49 }) === 1, '<50 lines takes the 1-group bracket')
ok(await groups({ diffLines: 50 }) === 2, '50 lines takes the 2-group bracket')
ok(await groups({ diffLines: 200 }) === 2, '200 lines is still the medium bracket')
ok(await groups({ diffLines: 201 }) === 3, '>200 lines takes the 3-group bracket')
ok(await groups({ diffLines: 900, fold: true }) === 1, 'fold forces the 1-group shape')

// --- receipt ingestion gate ------------------------------------------------------
// Each of these is a way to answer without reviewing. All must land as a channel
// failure, never as a clean dimension (protocol.md §7).
const chFail = async (rec) => {
  const impl = `(p, o) => ({ moreFindingsExist: false, findings: [], receipt: ${JSON.stringify(rec)} })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  return result.failedDimensions.length > 0
}
ok(await chFail(receipt({ tokens: ['wrong', 'tok-b'] })), 'wrong token a is a channel failure')
ok(await chFail(receipt({ tokens: ['tok-b', 'tok-a'] })), 'swapped tokens are a channel failure')
ok(await chFail(receipt({ paths: [] })), 'empty receipt.paths is a channel failure')
ok(await chFail(receipt({ paths: ['/etc/passwd'] })), 'an absolute path outside the root fails')
ok(await chFail(receipt({ paths: ['../../.env'] })), 'a .. escape fails')
ok(await chFail(receipt({ unread: ['changeset.diff', 'spec.md'] })), 'declaring the whole payload unread fails')
ok(await chFail(receipt({ unread: ['never-sent.txt'] })), 'unread naming an undispatched path fails')
ok(await chFail(receipt({ dimensions: ['correctness'] })), 'an uncovered assigned dimension fails')
ok(await chFail(receipt({ dimensions: ['vibes', 'correctness', 'security', 'edge-cases', 'spec-compliance'] })),
  'a dimension outside the fixed four fails')
{
  const impl = `(p, o) => ({ moreFindingsExist: false, findings: [] })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.failedDimensions.length > 0, 'a missing receipt is a channel failure')
}
// A well-formed clean sweep must NOT be reported as a failure.
{
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 })
  ok(result.failedDimensions.length === 0, 'a valid clean sweep is not a channel failure')
  ok(result.receipts.length === 1, 'a valid sweep records its receipt for reviewed_scope')
}

// --- a dead reviewer is not a clean dimension ------------------------------------
{
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, `() => null`)
  ok(result.failedDimensions.length === 1, 'a null (dead) reviewer is a channel failure')
}

// --- severity routing: C/H verified, M/L passed through --------------------------
const F = (sev, i) => ({ severity: sev, file: 'a.js', line: i, claim: 'c' + i, evidence: 'e' + i })
const REVIEW_WITH = (findings) => `(p, o) => o.phase === 'Review'
  ? ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })
  : ({ verdicts: ${JSON.stringify(findings.filter(f => f.severity === 'C' || f.severity === 'H')
      .map((_, i) => ({ i, real: true, reason: 'r', basis: 'not_applicable' })))} })`
{
  const findings = [F('C', 1), F('H', 2), F('M', 3), F('L', 4)]
  const { result, calls } = await run({ ...GOOD_ARGS, diffLines: 10 }, REVIEW_WITH(findings))
  ok(result.upheld.length === 2, 'both C/H are verified and upheld')
  ok(result.unverified.length === 2, 'M/L pass through unverified')
  ok(calls.filter(c => c.phase === 'Verify').length === 1, 'C/H are batched into one verifier call, not one per finding')
  ok(calls.filter(c => c.phase === 'Verify').every(c => c.model === 'opus'), 'verification runs on opus')
  ok(calls.filter(c => c.phase === 'Review').every(c => c.model === 'sonnet'), 'review runs on sonnet')
  // The verifier prompt must carry the finding text but NOT the receipt tokens:
  // echoing them would make the receipt answerable from the prompt (protocol.md §2).
  const vp = calls.find(c => c.phase === 'Verify').prompt
  ok(!vp.includes('tok-a') && !vp.includes('tok-b'), 'receipt tokens never reach a prompt')
  const rp = calls.find(c => c.phase === 'Review').prompt
  ok(!rp.includes('tok-a') && !rp.includes('tok-b'), 'receipt tokens never reach the review prompt')
  ok(rp.includes('deadbeef'), 'the payload digest is in the prompt, so changed bytes are a cache miss')
}

// --- a short or dead verifier leaves C/H unresolved, never silently upheld -------
{
  const findings = [F('C', 1), F('H', 2)]
  const impl = `(p, o) => o.phase === 'Review'
    ? ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })
    : ({ verdicts: [{ i: 0, real: true, reason: 'r', basis: 'not_applicable' }] })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.unresolved.length === 1, 'a verdict the verifier never returned leaves that C/H unresolved')
  ok(result.upheld.length === 1, 'the finding it did rule on is still upheld')
}
{
  const findings = [F('C', 1)]
  const impl = `(p, o) => o.phase === 'Review'
    ? ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })
    : null`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.unresolved.length === 1, 'a dead verifier leaves its C/H unresolved, not upheld')
  ok(result.upheld.length === 0, 'a dead verifier upholds nothing')
}
// A malformed verdict entry must be dropped, not indexed into or read as truthy.
{
  const findings = [F('C', 1)]
  const impl = `(p, o) => o.phase === 'Review'
    ? ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })
    : ({ verdicts: [null, { i: 0, real: 'yes', reason: 'r', basis: 'not_applicable' }] })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.unresolved.length === 1, 'a non-boolean `real` does not silently confirm a finding')
}

// --- rejection handling ----------------------------------------------------------
{
  const findings = [F('C', 1), F('C', 2)]
  const impl = `(p, o) => o.phase === 'Review'
    ? ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })
    : ({ verdicts: [
        { i: 0, real: false, reason: 'safe', basis: 'safe_behavior' },
        { i: 1, real: false, reason: 'barred', basis: 'unresolved_access' }] })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.rejected.length === 1, 'a real refutation lands in rejected')
  ok(result.rejected[0].rejectedOn === 'safe_behavior', 'the rejection carries its basis, not just a count')
  ok(result.rejected[0].claim === 'c1', 'rejections travel whole, with the finding text')
  ok(result.accessBlocked.length === 1, 'unresolved_access is its own key, not a rejection')
  ok(result.unresolved.length === 0, 'unresolved_access is not folded into unresolved')
  ok(result.upheld.length === 0, 'a refuted finding is not upheld')
}

// --- cap accounting --------------------------------------------------------------
{
  const findings = Array.from({ length: 20 }, (_, i) => F('M', i))
  const impl = `(p, o) => ({ moreFindingsExist: true, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.cappedDimensions.length === 1, 'a dimension that hit the cap is reported as truncated, not covered')
}
{
  // A reviewer that forgets the flag but returns a full list must still count as capped.
  const findings = Array.from({ length: 20 }, (_, i) => F('M', i))
  const impl = `(p, o) => ({ moreFindingsExist: false, findings: ${JSON.stringify(findings)}, receipt: ${JSON.stringify(receipt())} })`
  const { result } = await run({ ...GOOD_ARGS, diffLines: 10 }, impl)
  ok(result.cappedDimensions.length === 1, 'a full list without the flag is still capped')
}

if (fails === 0) console.log('PASS: A6 acceptance template (args guard, void round, brackets, receipt gate, verify routing, rejections, caps)')
process.exit(fails)
