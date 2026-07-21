# babel Per-Phase Playbook

Audience: the lead LLM running babel. Each section is an executable procedure referenced from the corresponding phase in SKILL.md. Communication rules, packet formats, and error handling are not restated here → **see protocol.md**. This file covers only "when, to whom, what, and in what order to dispatch."

---

## debate-aggregation

Used in Phase 1 (design). Run only when triage classifies the task as M/L. For S, skip and let the lead design alone.

0. **Fix the canonical data channel** (data/replication tasks only, before design): decide at this stage the primary sources the deliverable must ground on and the "non-degrading way to read them," and record them in the `canon` field of the TaskPacket (protocol.md §2). Retrofitting this after design or after acceptance leads the implementation worker to fill it via a convenient degraded path (image OCR only, eyeballing a screenshot only), creating gaps (a defect root cause observed on a real task). Propagate `canon` into every subsequent implementation/repair TaskPacket. Non-data tasks skip this step.
1. **Parallel launch**: once user Q&A via superpowers:brainstorming is done, **before** the lead starts writing its own proposal, dispatch the identical DesignPacket request (TaskPacket, out_schema=DesignPacket; protocol.md §2) to SOL+agy simultaneously via `run_in_background`.
2. **Anchoring-avoidance barrier**: the lead writes its own proposal (equivalent to a DesignPacket) to completion without reading the external responses. Ordering is guaranteed by procedure, not by code — place the actions that wait for or check the external calls' output after the lead's own proposal is complete.
3. **L only**: within Claude, generate independent per-viewpoint designs (MVP-first / risk-first / user-first) as a mixed Sonnet/Opus generation via the Workflow tool's `parallel()` (the blueprint uses the same `agent()` API as the acceptance-gate template; schema is DesignPacket format).
4. **Integration**: consolidate all proposals (own + SOL + agy + Claude-internal viewpoints) into an agreement matrix plus points of difference.
5. **Resolving differences**: the lead first fills cross-system differences with grounding (primary sources / actual code). Dynamic arbitration delegation to the domain-strongest model (algorithmic→SOL / API spec→agy, sending only the points of difference) is in `advanced.md` §A4. If they cannot be filled, the lead does a final reconsideration at maximum depth (SKILL.md "think at maximum depth when stuck") → if that still fails, user gate "design differences."

### SOL launch command template

Write the payload to `.babel/<task>/inbox/design-req.json` and have SOL read it itself via `--cwd` (protocol.md §3, to avoid the argv limit). Do not use protocol.md pointers with SOL; embed the output format inline each time (protocol.md §11).

```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/design-req.json. Read it and referenced files. Output DesignPacket JSON only: {approach:str, decisions:[str], risks:[str], tradeoffs:[str], rec:str}. Example: {\"approach\":\"JWT rotation via refresh token\",\"decisions\":[\"15min access TTL\"],\"risks\":[\"clock skew\"],\"tradeoffs\":[\"extra round trip\"],\"rec\":\"adopt\"}. No prose outside JSON."
```

- `--tier normal` (normal for design, deep for diagnosis/critical acceptance).
- Bash `timeout: 600000` (required per cdx-sol SKILL.md; the default 120s kills long-running executions) plus `run_in_background: true`. Wait for the completion notification together with agy's.

### agy launch command template

agy cannot read the fs (protocol.md §1) → do not reference a path to spec.md; inline the spec essentials (goal/criteria/constraints) into the prompt. Use python3 (in the stub environment python3.13/py -3.13, see the SKILL.md crew table) plus the heredoc environment-variable approach (per agy SKILL.md, to avoid double-quote accidents). Keep the payload to the diff-hunk equivalent only and be mindful of the size limit (summarize before sending when it exceeds).

```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"independent design for <task summary>. Spec essentials: <summarize spec.md's goal/criteria/constraints inline here>","files":[],"inputs":[],"criteria":["<acceptance criteria>"],"constraints":["<constraints>"],"out_schema":"DesignPacket"}
Output DesignPacket JSON only, no prose. Do not use any tools — answer directly from the text given above.
EOF
)
python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 180
```

Use Bash-side `timeout: 200000` alongside (per agy SKILL.md).

---

## build-debug

Used in Phase 2 (implementation). Connects to superpowers:executing-plans / subagent-driven-development. The only babel-specific additions are checkpoint verification and model assignment.

1. After task decomposition, delegate mechanical tasks (boilerplate implementation, replacements, template filling) to Sonnet subagents; the lead writes the core logic (core implementation requiring design judgment).
2. **Cascade**: Sonnet does the first-pass draft/screening, and only what passes is scrutinized by a higher model (lead/Opus). Do not route everything through the higher model.
3. **Checkpoint verification (optional)**: at each milestone, run a spec-drift/bug check with SOL quick. **Skip condition**: for small tasks where the milestone diff coincides with the task's final changeset as a whole, skip and fold into Phase 3 acceptance (avoiding double dispatch). Mechanism and launch template are in `advanced.md` §A3.
4. Findings are received as finding-jsonl (protocol.md §2) with the schema-verification gate (§7). Fix C/H immediately before moving on; record M/L and pick them up at acceptance-gate.

**When stuck** (two consecutive failed fixes on the same file/symbol), go to `#sequential-switching` = `advanced.md` §A2 (SOL deep→agy→lead maximum depth→user).

---

## sequential-switching

The diagnosis-handoff playbook for when stuck in Phase 2 (two consecutive failed fixes on the same problem) → `advanced.md` §A2.

---

## acceptance-gate

Used in Phase 3 (acceptance). Applied by scale: **S = Claude adversarial review, 1 reviewer only** (run (a) with a single reviewer; skip the rest of this section. If an external reviewer is already up, SOL quick is fine, but small diffs are prone to SOL false positives, so Claude adversarial is the default). M = 1 round: 3-system review (a)(b)(c) plus the lead's merge and C/H fixes. The re-run loop, convergence check, and completeness critic in step 5 are L-only. For M, post-fix confirmation is a single change-impact reviewer only (re-run only one system among those whose scope intersects the fix diff and that reported the original finding; when multiple qualify, prefer SOL). L = full section. See SKILL.md Phase 0 for crew composition.

**Review target = the actual changeset at the start of Phase 3** (fix the list of actually-edited files via `git diff --name-only` etc.). Not the file list estimated during Phase 0 triage — if a shared module out of scope was touched during implementation, include it too (agy review #8).

**The substance of the CHANGESET**: at the start of Phase 3, the lead creates `.babel/<task>/inbox/changeset.diff` (unified diff) plus a list of changed files. Reviewers that can read the fs (SOL / Claude subagents) receive it by path, and agy receives the hunks inline. For spec-compliance review, distribute `.babel/<task>/spec.md` the same way (inline the essentials for agy).

### Procedure

1. Fix the changeset and dispatch the 3 systems.
   - (a) Claude adversarial Workflow: the lead dynamically generates and runs a Workflow script on the spot (template below). The (a) Workflow adversarial verification is L-only. For M, the lead runs a simplified review with parallel Agents and does not use the Opus adjudication stage. **Reviewer count scales with diff size** (guideline; line counts are for the whole changeset): under 50 lines = 1 reviewer (one reviewer covers all dimensions) / 50–200 lines = 2 reviewers / over 200 lines = 3 reviewers (dimension split). Pilot 1 measurement: 3 reviewers for a 44-line diff was excessive, reduced to 1.
   - (b) agy: request review of the changeset's diff hunks inline.
   - (c) SOL normal: pass the changeset path via `.babel/<task>/inbox/` and request review.
   - (b)(c) are dispatched simultaneously via `run_in_background`. (a) runs inside the lead's session.
2. **Mutually blind reviewers within a round**: (a)(b)(c) do not receive each other's findings within the same round. Only the lead merges and cross-references (protocol.md §8).
3. Once all systems' findings are in, the lead merges (merge procedure below).
4. The lead fills cross-system differences with grounding (dynamic arbitration in `advanced.md` §A4).
5. Evaluate the convergence condition; if not converged, re-dispatch only the relevant reviewers (change-impact routing, protocol.md §9).

### (a) Claude adversarial Workflow template

Generate per-dimension (correctness / security / edge-cases / spec-compliance) in parallel via `pipeline()` → adversarially verify each finding (Sonnet first-pass generation → Opus live/dead adjudication). **The full (a) Workflow template (JS) is in `advanced.md` §A6.** The (a) Workflow adversarial verification is L-only. **For M, the lead runs a simplified review with parallel Agents** (does not use the Opus adjudication stage). In environments without the Workflow tool, substitute per-dimension review with parallel Agents.

### (b)(c) template

(c) SOL: reuse the build-debug checkpoint template and change the goal to acceptance.
```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket: goal='full review of changeset', files=[{path:'<path to changeset file list>'}], out_schema='finding-jsonl or NONE'. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence 15-30tok>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Bash `timeout: 600000` + `run_in_background: true`. For critical acceptance of an L task that is security/irreversible, swap in `--tier deep` (see the cost discipline in SKILL.md).

(b) agy: PTY wrapper. Pass the changeset's diff hunks inline, and include the finding-jsonl format line plus one example line inside the prompt (inline, like SOL). Be mindful of the payload size limit; when it exceeds, split or degrade (same criteria as the design template, protocol.md §3).
```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"full review of changeset","files":[{"path":"<diff hunk summary>"}],"inputs":[],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Diff hunk: <paste the changed diff hunks inline>
Output one JSON array per line: ["<id>","<sev C|H|M|L>","<file>",<line>,"<claim>","<evidence 15-30tok>"]. Example: ["F1","C","auth.py",42,"token expiry unchecked","verify_token() decodes JWT without checking exp claim"]. Output NONE (single word) if clean. No prose. Do not use any tools — answer directly from the text given above.
EOF
)
python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 240
```
Bash `timeout: 300000` + `run_in_background: true`. A whole-changeset review is heavier than a design request, so agy's timeout is extended to 240/300000 (intentional).

### Merge procedure

1. **Fingerprint dedup**: match on `{path, symbol (function name / spec section ID), violated invariant}`. Do not use line numbers in the dedup key (protocol.md §7). Matching is a semantic comparison by the lead.
2. Match against **both** the already-reported list and the already-rejected list (to prevent re-surfacing loops).
3. Verify C/H only: batch 8–12 surviving findings per call. If a repro can be run, verify with the reproduction command / failing test; if not possible, substitute an invariant argument (protocol.md §7; the repro safety rules are in the same section).
   **SOL findings on small diffs need grounding confirmation**: the smaller the changeset (guideline: under 50 lines), the higher SOL's acceptance false-positive rate (pilot 1 measurement: flagged trailing whitespace that did not exist). For an SOL-only finding on a small diff, always confirm the actual lines of the file in question during the verification stage before adopting it (a finding that agrees with another system may have its priority raised). Apply the same to S acceptance (SOL quick, single pass).
4. Fix what passes verification. **Obligation to re-ground before repair**: do not fix by trusting an audit finding as-is. Before starting a fix, re-confirm the location against primary sources (`canon` channel / the actual line of the real file) and verify whether the finding's premise actually holds. Audits can produce false detections (pilot 2: the R4 system spontaneously re-grounded and prevented 2 false detections). The repair TaskPacket must always include in `constraints`: "before fixing, re-ground against canon and confirm the finding's premise."
5. Re-run with **change-impact routing**: re-dispatch only the reviewers whose previous scope or unresolved findings intersect the fixed file/function (do not re-send to unrelated reviewers). **For L multi-round, further narrow crew composition with `channel_scoreboard`** (protocol.md §5) — drop from the next round any channel with grounding confirmed=0 and refuted≥2 over the last 2 rounds (within-task online adaptation, details in `advanced.md` §A9). Each finding's grounding outcome (confirmed/refuted) is appended to the scoreboard at this merge stage (lead exclusively).
6. Have M/L output in line form the same as C/H, but do not verify or fix them. Present them together to the user in the final report.

### Termination condition

- **Convergence**: in some round, zero new C/H, and the immediately following completeness critic (L-only, `advanced.md` §A5) is also empty. If round 1 is clean, converge immediately. Only when a fix occurred, re-run the relevant system, and converge when the post-fix round has zero new C/H.
- **Cap (difficulty-linked)**: default 4 rounds. **While new C/H keeps decreasing every round, do not consume the cap** (if trending toward convergence, auto-extend up to +2; pilot 2's single hard spot required 7 rounds). Consume 1 cap only on a flat/divergent round. On extension, note it to the user in one line (including the increased estimated tokens). Before reaching the cap, the lead does one final reconsideration at maximum depth. If new C/H still remain, present the residual findings to the user (user gate "acceptance result" / "residual risk").
- **Crew stretch/shrink for L multi-round**: read the above convergence/extension decisions together with the grounding outcomes in `channel_scoreboard` — channel dropping, routing weighting, and early folding are scoreboard-driven (`advanced.md` §A9). Drive on grounding outcomes only, not on subjective evaluation (protocol.md §7 invariant). The scoreboard is ephemeral, discarded at task end and not written back into the protocol.
