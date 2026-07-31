# babel Per-Phase Playbook

Audience: the lead LLM running babel. Each section is an executable procedure referenced from its phase in SKILL.md. For communication rules, packet formats, and error handling → **see protocol.md**. This file covers only "when, to whom, what, and in what order to dispatch."

**Reading map by scale** — read only what the scale fires; the rest is dead weight in context:
- **S**: `#build-debug` + the first paragraph of `#acceptance-gate` (S = one reviewer, one-shot) + protocol.md §0-§4 and §7 (grounding before fixing and repro safety bind at every scale). Skip `#debate-aggregation`, the merge loop, and termination conditions.
- **M**: adds `#debate-aggregation`, the full `#acceptance-gate` procedure and merge (one round, no loop), protocol.md §5 (M shape) / §8-§10.
- **L**: everything, plus advanced.md as pointed to (A1/A5/A6/A9 fire only at L).
- advanced.md §A2 (stuck playbook) and §A3 (checkpoint) are Phase 2 events, not scale gates — they can fire at any scale; open them when they fire, not before.

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
solask --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/design-req.json. Read it and referenced files. Output DesignPacket JSON only: {approach:str, decisions:[str], risks:[str], tradeoffs:[str], rec:str}. Example: {\"approach\":\"JWT rotation via refresh token\",\"decisions\":[\"15min access TTL\"],\"risks\":[\"clock skew\"],\"tradeoffs\":[\"extra round trip\"],\"rec\":\"adopt\"}. No prose outside JSON."
```

- `--tier normal` (normal for design, deep for diagnosis/critical acceptance).
- Bash `timeout: 600000` (required per cdx-sol SKILL.md; the default 120s kills long runs) plus `run_in_background: true`. Wait for the completion notification together with agy's.

### agy launch command template

agy cannot read the fs (protocol.md §1) → do not reference a path to spec.md; inline the spec essentials (goal/criteria/constraints) into the prompt. Use the heredoc env-var form below (avoids double-quote accidents). Keep the payload to the diff-hunk equivalent only, under the 32 KB cap (protocol.md §3).

```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"independent design for <task summary>. Spec essentials: <summarize spec.md's goal/criteria/constraints inline here>","files":[],"inputs":[],"criteria":["<acceptance criteria>"],"constraints":["<constraints>"],"out_schema":"DesignPacket"}
Output DesignPacket JSON only, no prose. Do not use any tools — answer directly from the text given above.
EOF
)
[ "$(printf '%s' "$PROMPT" | wc -c)" -lt 32768 ] || { echo 'over the 32 KB cap — split or drop agy (protocol.md §3)' >&2; exit 1; }
AGY_PRINT_TIMEOUT=180s agyask "$PROMPT"
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

Phase 3 by scale: **S = one adversarially-prompted Claude reviewer** — a single Agent covering all four dimensions, *not* the (a) Workflow (no Opus verify stage, no script); skip the rest. SOL quick is acceptable if already running, but Claude is default because small diffs raise SOL false positives. **M = one (a)(b)(c) round**, lead merge, and C/H fixes; no step-5 loop, convergence check, or completeness critic. After an M fix, re-run one change-impact reviewer whose scope intersects the fix and reported the finding; prefer SOL when several qualify. **The M re-review payload is not an A1 delta** — M's state has no cursors or snapshots (SKILL.md Phase 0 shapes). Rebuild the changeset diff for the fix's paths only (`git diff <baseline-commit> -- <paths>`, minus baseline hunks as above, **plus `git diff --no-index /dev/null <path>` for any fixed path that is untracked** — exactly as the main changeset build does, since a task-created file emits nothing from `git diff` against the baseline commit) and send that; it is slightly wider than a true delta and needs no multi-round machinery. That re-review fires **exactly once**: fix any new C/H it returns, then stop. M has no loop, so anything still open after that fix goes to the user as residual risk (user gate) rather than into another round — otherwise the re-review is an unbounded loop wearing M's clothes. **L = full section.** See SKILL.md Phase 0.

**Review target = the actual changeset at the start of Phase 3**, not the file list estimated during Phase 0 triage — if an out-of-scope shared module was touched during implementation, include it too (agy review #8).

**The task delta, precisely.** Phase 0 records a baseline in `state.json` as `"baseline":{"commit":"<git rev-parse HEAD>","dirty":["<paths already modified before babel started>"]}`, plus `.babel/<task>/baseline.diff` holding those pre-existing hunks verbatim when `dirty` is non-empty. The Phase 3 changeset is everything that changed since that baseline **minus** that pre-existing work — reviewing the user's unrelated work in progress wastes a round and produces findings nobody asked for.

Subtract at hunk granularity, not path granularity. A path in `dirty` that the task never touched drops out whole; a path in `dirty` that the task *did* edit stays in, with the hunks already present in `baseline.diff` excluded — dropping the whole file instead would hide the task's own edits to it, which is the worse of the two errors. Exclusion means exact-match: a current hunk identical to a `baseline.diff` hunk drops out; a current hunk that overlaps a baseline hunk but no longer matches it (the task edited the same region the user had touched) **goes in whole, deliberately** — the two authors cannot be separated inside one hunk, and hiding the task's edit is the worse error, same rule as the untracked-edited case below. Note it in the acceptance report so findings against the user's lines are not read as findings against the task.

Build it so nothing is silently dropped: `git diff <baseline-commit>` covers tracked edits **including staged ones**, and `git status --porcelain` names untracked files, which a plain diff omits entirely — a new file is exactly where a fresh defect hides. Write the unified diff to `.babel/<task>/inbox/changeset.diff` (untracked files appended via `git diff --no-index /dev/null <path>`) and the file list to `.babel/<task>/inbox/changeset-files.txt`. On a multi-round L run, also copy each changeset file verbatim to `.babel/<task>/snap-r<N>/<repo-relative-path>` at dispatch — the snapshots the inter-round delta is built from. How the per-channel delta is built, named, and sent (laggard channels, added/deleted paths, the diff-of-diffs trap) is defined once in `advanced.md` §A1; the state fields it reads are `protocol.md` §5. Reviewers that can read the fs (SOL / Claude subagents) receive diffs by path; agy receives the hunks inline. For spec-compliance review, distribute `.babel/<task>/spec.md` the same way (inline the essentials for agy).

### Procedure

1. Fix the changeset and dispatch the 3 systems.
   - (a) Claude adversarial Workflow: generate/run the script below. Adversarial verification is L-only; M uses parallel Agents without Opus adjudication. **L round 1 exception**: (a) starts folded at one agent regardless of diff size (measured prior, `advanced.md` §A9) unless it is the only track. Otherwise scale reviewers by changed lines — the four dimensions are always all covered, what changes is how many agents share them:
     - **under 50 lines → 1 agent** carrying all four dimensions in one prompt (pilot 1 showed 3 reviewers excessive for 44 lines);
     - **50-200 → 2 agents**: `correctness + edge-cases` / `security + spec-compliance`;
     - **over 200 → 3 agents**: `correctness` / `security` / `edge-cases + spec-compliance`.
     Do not hand-set the grouping in the template: pass the measured **changed-line count** (added+removed, not the diff file's `wc -l` — context lines inflate it 2-3×) as `args.diffLines` and A6 selects the bracket itself (it is not fixed at four agents).
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

(c) SOL: write the TaskPacket to `.babel/<task>/inbox/accept-r<N>.json` (argv avoidance, protocol.md §3) and point SOL at it. **Round 1 names `changeset.diff`; from round 2 on, name SOL's own delta** — `delta-r<N>.diff`, or its `-sol` variant if SOL lagged a round — since re-sending the whole changeset re-reviews what it already cleared. The exception is a channel with no `last_seen`, one that has never returned a clean result: it has no snapshot to diff from and gets the full changeset regardless of round (`advanced.md` §A1). Same for (b) agy below, and for the Claude template (`advanced.md` §A6). The packet must name the diff itself, not just the file list — a list of paths sends SOL to read current file contents, which after a later fix is no longer the changeset that was reviewed:
```json
{"goal":"full review of changeset",
 "files":[{"path":".babel/<task>/inbox/changeset.diff"},{"path":".babel/<task>/spec.md"}],
 "inputs":[".babel/<task>/inbox/changeset-files.txt"],
 "criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
```
```bash
solask --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/accept-r<N>.json. Read it and the referenced files. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence ~10-25 words>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Bash `timeout: 600000` + `run_in_background: true`. For critical acceptance of a security/irreversible L task, swap in `--tier deep` (see the cost discipline in SKILL.md).

(b) agy: pass the changeset's diff hunks inline, and include the finding-jsonl format line plus one example line in the prompt (inline, like SOL). Check the payload against the 32 KB cap before dispatch; over it, split the hunks or degrade (protocol.md §3).
```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"full review of changeset","files":[{"path":"<diff hunk summary>"}],"inputs":[],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Diff hunk: <paste the changed diff hunks inline>
Output one JSON array per line: ["<id>","<sev C|H|M|L>","<file>",<line>,"<claim>","<evidence ~10-25 words>"]. Example: ["F1","C","auth.py",42,"token expiry unchecked","verify_token() decodes JWT without checking exp claim"]. Output NONE (single word) if clean. No prose. Do not use any tools — answer directly from the text given above.
EOF
)
[ "$(printf '%s' "$PROMPT" | wc -c)" -lt 32768 ] || { echo 'over the 32 KB cap — split or drop agy (protocol.md §3)' >&2; exit 1; }
AGY_PRINT_TIMEOUT=240s agyask "$PROMPT"
```
Bash `timeout: 300000` + `run_in_background: true`. A whole-changeset review is heavier than a design request, so agy's timeout is intentionally extended to 240/300000.

### Merge procedure

1. **Fingerprint dedup**: match on `{path, symbol (function name / spec section ID), violated invariant}`. Do not use line numbers in the dedup key (protocol.md §7). Matching is a semantic comparison by the lead.
2. Match against **both** the already-reported and already-rejected lists (prevents re-surfacing loops).
3. Verify C/H only: batch 8–12 surviving findings per call. If a repro can run, verify with the reproduction command / failing test; if not, substitute an invariant argument (protocol.md §7, same section for repro safety rules).
   **Ground SOL findings on small diffs**: under 50 lines, SOL acceptance has more false positives (pilot 1 reported nonexistent trailing whitespace). Before adopting an SOL-only finding, confirm actual file lines; multi-system agreement may raise priority. Apply this to S SOL-quick acceptance too.
4. Fix verified findings only. **Re-ground before repair** against primary sources (`canon` / actual file line) and confirm the premise; never trust an audit finding as-is. This is a premise re-check against the file as it stands now — an earlier fix may have moved or already closed it — not a second grounding event: the finding keeps the one `confirmed`/`refuted` label step 3 gave it, and nothing is appended to `channel_scoreboard` here (protocol.md §7, "each is grounded once"). Pilot 2's R4 re-grounding prevented 2 false detections. Every repair TaskPacket must include constraint: `before fixing, re-ground against canon and confirm the finding's premise.`
5. Re-run with **change-impact routing**: re-dispatch only the reviewers whose previous scope or unresolved findings intersect the fixed file/function (not unrelated reviewers). **For L multi-round, further narrow crew composition with `channel_scoreboard`** (protocol.md §5) — drop from the next round any channel with grounding confirmed=0 and refuted≥2 over the last 2 rounds (within-task online adaptation, `advanced.md` §A9). Each finding's grounding outcome (confirmed/refuted) is appended to the scoreboard at this merge stage (lead exclusively).
6. Output M/L in line form like C/H, but do not verify or fix them. Present them to the user in the final report.

### Termination condition

- **Convergence**: a round with zero new C/H is a *candidate* clean round, not convergence. Run the completeness critic (L-only, `advanced.md` §A5) after it and converge only if the critic is empty too. This holds for round 1 as well — a clean first round is the case where an uncovered dimension is most likely to be the reason nothing was found.
- **Cap — two counters, two distinct triggers.** The hard ceiling is **`round` = 8**; no path extends past it. The user-approval trigger is **`budget.rounds_consumed` = 4**: before dispatching a round that would run with 4 already consumed, ask, with the added token estimate attached. **A round on which new C/H decreased consumes nothing** — trending toward convergence is not the failure mode either trigger exists for; a flat or divergent round consumes 1 (protocol.md §5 defines both counters; `round` also names result files and scoreboard entries, which is why it increments every dispatch regardless). So a task that converges steadily can run all 8 rounds without ever asking, and a task that thrashes asks after its 4th non-progressing round (pilot 2's hard spot: 7 rounds total, under the ceiling, approval obtained on the consumed-budget trigger). At the ceiling, the lead does one final reconsideration at maximum depth, then presents residual findings to the user (user gate "acceptance result" / "residual risk").
- **Crew stretch/shrink for L multi-round**: read the above convergence/extension decisions together with `channel_scoreboard` outcomes — channel dropping, routing weighting, and early folding are scoreboard-driven (`advanced.md` §A9; ephemeral, grounding-driven only, per protocol.md §7 invariant).
