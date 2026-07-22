# babel Per-Phase Playbook

Audience: the lead LLM running babel. Each section is an executable procedure referenced from its phase in SKILL.md. For communication rules, packet formats, and error handling → **see protocol.md**. This file covers only "when, to whom, what, and in what order to dispatch."

---

## debate-aggregation

Used in Phase 1 (design). Run only when triage classifies the task as M/L. For S, skip and let the lead design alone.

0. **Fix the canonical data channel** (data/replication tasks only, before design): decide the primary sources the deliverable must ground on and the "non-degrading way to read them," and record them in the TaskPacket `canon` field (protocol.md §2). Retrofitting this after design or acceptance leads the implementation worker to fill it via a degraded path (image OCR only, eyeballing a screenshot), creating gaps (a real-task defect root cause). Propagate `canon` into every subsequent implementation/repair TaskPacket. Non-data tasks skip this step.
1. **Parallel launch**: once user Q&A via superpowers:brainstorming is done, and **before** the lead writes its own proposal, dispatch the identical DesignPacket request (TaskPacket, out_schema=DesignPacket; protocol.md §2) to SOL+agy simultaneously via `run_in_background`.
2. **Anchoring-avoidance barrier**: the lead writes its own proposal (a DesignPacket) to completion without reading the external responses. Ordering is guaranteed by procedure, not code — place the actions that wait for or check the external output after the lead's proposal is complete.
3. **L only**: within Claude, generate independent per-viewpoint designs (MVP-first / risk-first / user-first) as a mixed Sonnet/Opus generation via the Workflow tool's `parallel()` (blueprint uses the same `agent()` API as the acceptance-gate template; schema is DesignPacket).
4. **Integration**: consolidate all proposals (own + SOL + agy + Claude-internal viewpoints) into an agreement matrix plus points of difference.
5. **Resolving differences**: the lead first fills cross-system differences with grounding (primary sources / actual code). Dynamic arbitration to the domain-strongest model (algorithmic→SOL / API spec→agy, sending only the differences) is in `advanced.md` §A4. If differences cannot be filled, the lead reconsiders at maximum depth (SKILL.md "think at maximum depth when stuck") → if that still fails, user gate "design differences."

### SOL launch command template

Write the payload to `.babel/<task>/inbox/design-req.json` and have SOL read it via `--cwd` (protocol.md §3, to avoid the argv limit). Do not use protocol.md pointers with SOL; embed the output format inline each time (protocol.md §11).

```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/design-req.json. Read it and referenced files. Output DesignPacket JSON only: {approach:str, decisions:[str], risks:[str], tradeoffs:[str], rec:str}. Example: {\"approach\":\"JWT rotation via refresh token\",\"decisions\":[\"15min access TTL\"],\"risks\":[\"clock skew\"],\"tradeoffs\":[\"extra round trip\"],\"rec\":\"adopt\"}. No prose outside JSON."
```

- `--tier normal` (normal for design, deep for diagnosis/critical acceptance).
- Bash `timeout: 600000` (required per cdx-sol SKILL.md; the default 120s kills long runs) plus `run_in_background: true`. Wait for the completion notification together with agy's.

### agy launch command template

agy cannot read the fs (protocol.md §1) → do not reference a path to spec.md; inline the spec essentials (goal/criteria/constraints) into the prompt. Use python3 (stub environment: python3.13/py -3.13, see the SKILL.md crew table) plus the heredoc env-var approach (per agy SKILL.md, to avoid double-quote accidents). Keep the payload to the diff-hunk equivalent only, and mind the size limit (summarize before sending when it exceeds).

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

Phase 2 procedure over superpowers:executing-plans / subagent-driven-development; babel adds only checkpoint verification and model assignment.

1. After task decomposition, delegate mechanical tasks (boilerplate, replacements, template filling) to Sonnet subagents; the lead writes the core logic requiring design judgment.
2. **Cascade**: Sonnet does the first-pass draft/screening; only what passes is scrutinized by a higher model (lead/Opus). Do not route everything through the higher model.
3. **Checkpoint verification (optional)**: at each milestone, run a spec-drift/bug check with SOL quick. **Skip condition**: for small tasks where the milestone diff equals the task's final changeset, skip and fold into Phase 3 acceptance (avoids double dispatch). Mechanism and launch template in `advanced.md` §A3.
4. Receive findings as finding-jsonl (protocol.md §2) with the schema-verification gate (§7). Fix C/H immediately before moving on; record M/L and pick them up at acceptance-gate.

**When stuck** (two consecutive failed fixes on the same file/symbol), go to `#sequential-switching` = `advanced.md` §A2 (SOL deep→agy→lead maximum depth→user).

---

## sequential-switching

The diagnosis-handoff playbook for when stuck in Phase 2 (two consecutive failed fixes on the same problem) → `advanced.md` §A2.

---

## acceptance-gate

Phase 3 by scale: **S = one Claude adversarial reviewer** using (a); skip the rest. SOL quick is acceptable if already running, but Claude is default because small diffs raise SOL false positives. **M = one (a)(b)(c) round**, lead merge, and C/H fixes; no step-5 loop, convergence check, or completeness critic. After an M fix, re-run one change-impact reviewer whose scope intersects the fix and reported the finding; prefer SOL when several qualify. **L = full section.** See SKILL.md Phase 0.

**Review target = the actual changeset at the start of Phase 3** (fix the list of actually-edited files via `git diff --name-only` etc.), not the file list estimated during Phase 0 triage — if an out-of-scope shared module was touched during implementation, include it too (agy review #8).

**The substance of the CHANGESET**: at the start of Phase 3, the lead creates `.babel/<task>/inbox/changeset.diff` (unified diff) plus a changed-file list. Reviewers that can read the fs (SOL / Claude subagents) receive it by path; agy receives the hunks inline. For spec-compliance review, distribute `.babel/<task>/spec.md` the same way (inline the essentials for agy).

### Procedure

1. Fix the changeset and dispatch the 3 systems.
   - (a) Claude adversarial Workflow: generate/run the script below. Adversarial verification is L-only; M uses parallel Agents without Opus adjudication. Scale reviewers by whole-changeset lines: under 50 = 1/all dimensions; 50-200 = 2; over 200 = 3/dimension split. Pilot 1 showed 3 reviewers excessive for 44 lines, so use 1.
   - (b) agy: request review of the changeset's diff hunks inline.
   - (c) SOL normal: pass the changeset path via `.babel/<task>/inbox/` and request review.
   - (b)(c) dispatch simultaneously via `run_in_background`. (a) runs inside the lead's session.
2. **Mutually blind reviewers within a round**: (a)(b)(c) do not receive each other's findings within the same round. Only the lead merges and cross-references (protocol.md §8).
3. Once all findings are in, the lead merges (merge procedure below).
4. The lead fills cross-system differences with grounding (dynamic arbitration in `advanced.md` §A4).
5. Evaluate the convergence condition; if not converged, re-dispatch only the relevant reviewers (change-impact routing, protocol.md §9).

### (a) Claude adversarial Workflow template

Run correctness / security / edge-cases / spec-compliance through `pipeline()` in parallel, then adversarially verify findings (Sonnet generation → Opus live/dead adjudication). Full L-only JS: `advanced.md` §A6. M uses parallel Agents without Opus; if Workflow is unavailable, use per-dimension parallel Agents.

### (b)(c) template

(c) SOL: reuse the build-debug checkpoint template and change the goal to acceptance.
```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket: goal='full review of changeset', files=[{path:'<path to changeset file list>'}], out_schema='finding-jsonl or NONE'. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence 15-30tok>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Bash `timeout: 600000` + `run_in_background: true`. For critical acceptance of a security/irreversible L task, swap in `--tier deep` (see the cost discipline in SKILL.md).

(b) agy: PTY wrapper. Pass the changeset's diff hunks inline, and include the finding-jsonl format line plus one example line in the prompt (inline, like SOL). Mind the payload size limit; when it exceeds, split or degrade (same criteria as the design template, protocol.md §3).
```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"full review of changeset","files":[{"path":"<diff hunk summary>"}],"inputs":[],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Diff hunk: <paste the changed diff hunks inline>
Output one JSON array per line: ["<id>","<sev C|H|M|L>","<file>",<line>,"<claim>","<evidence 15-30tok>"]. Example: ["F1","C","auth.py",42,"token expiry unchecked","verify_token() decodes JWT without checking exp claim"]. Output NONE (single word) if clean. No prose. Do not use any tools — answer directly from the text given above.
EOF
)
python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 240
```
Bash `timeout: 300000` + `run_in_background: true`. A whole-changeset review is heavier than a design request, so agy's timeout is intentionally extended to 240/300000.

### Merge procedure

1. **Fingerprint dedup**: match on `{path, symbol (function name / spec section ID), violated invariant}`. Do not use line numbers in the dedup key (protocol.md §7). Matching is a semantic comparison by the lead.
2. Match against **both** the already-reported and already-rejected lists (prevents re-surfacing loops).
3. Verify C/H only: batch 8–12 surviving findings per call. If a repro can run, verify with the reproduction command / failing test; if not, substitute an invariant argument (protocol.md §7, same section for repro safety rules).
   **Ground SOL findings on small diffs**: under 50 lines, SOL acceptance has more false positives (pilot 1 reported nonexistent trailing whitespace). Before adopting an SOL-only finding, confirm actual file lines; multi-system agreement may raise priority. Apply this to S SOL-quick acceptance too.
4. Fix verified findings only. **Re-ground before repair** against primary sources (`canon` / actual file line) and confirm the premise; never trust an audit finding as-is. Pilot 2's R4 re-grounding prevented 2 false detections. Every repair TaskPacket must include constraint: `before fixing, re-ground against canon and confirm the finding's premise.`
5. Re-run with **change-impact routing**: re-dispatch only the reviewers whose previous scope or unresolved findings intersect the fixed file/function (not unrelated reviewers). **For L multi-round, further narrow crew composition with `channel_scoreboard`** (protocol.md §5) — drop from the next round any channel with grounding confirmed=0 and refuted≥2 over the last 2 rounds (within-task online adaptation, `advanced.md` §A9). Each finding's grounding outcome (confirmed/refuted) is appended to the scoreboard at this merge stage (lead exclusively).
6. Output M/L in line form like C/H, but do not verify or fix them. Present them to the user in the final report.

### Termination condition

- **Convergence**: in some round, zero new C/H, and the immediately following completeness critic (L-only, `advanced.md` §A5) is also empty. If round 1 is clean, converge immediately. When a fix occurred, re-run the relevant system and converge when the post-fix round has zero new C/H.
- **Cap (difficulty-linked)**: default 4 rounds. **While new C/H keeps decreasing every round, do not consume the cap** (if trending toward convergence, auto-extend up to +2; pilot 2's single hard spot required 7 rounds). Consume 1 cap only on a flat/divergent round. On extension, note it to the user in one line (including the increased token estimate). Before reaching the cap, the lead does one final reconsideration at maximum depth. If new C/H still remain, present the residual findings to the user (user gate "acceptance result" / "residual risk").
- **Crew stretch/shrink for L multi-round**: read the above convergence/extension decisions together with `channel_scoreboard` outcomes — channel dropping, routing weighting, and early folding are scoreboard-driven (`advanced.md` §A9; ephemeral, grounding-driven only, per protocol.md §7 invariant).
