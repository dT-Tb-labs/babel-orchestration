# babel Per-Phase Playbook

Audience: the lead LLM running babel. Each section is an executable procedure referenced from its phase in SKILL.md. For communication rules, packet formats, and error handling → **see protocol.md**. This file covers only "when, to whom, what, and in what order to dispatch."

**Reading map by scale** — read only what the scale fires; the rest is dead weight in context:
- **S**: `#build-debug` + the first paragraph of `#acceptance-gate` (S = one reviewer, one-shot) **plus "Assert the payload before dispatching it"** — the non-empty/reviewable-lines gate binds at every scale, and S is where a silent empty round has no critic to catch it — + protocol.md §0-§4, §5 (only the `results/` naming and the S `state.json` shape), §7 and §10 (grounding before fixing and repro safety bind at every scale, and a dead reviewer at S is still a degradation row; **not §7b**, which needs a second channel to mean anything). Skip `#debate-aggregation`, the merge loop, and termination conditions.
- **M**: adds `#debate-aggregation`, the full `#acceptance-gate` procedure and merge (one round, no loop), protocol.md §5 (M shape) / **§7b** / §8-§10. §7b is the half of verification that needs a second channel — dedup fingerprints, duplicate credit, the verifier-rejection rules — and it is exactly what M adds over S.
- **L**: everything, plus advanced.md as pointed to (A1/A6/A9 fire only at L; **A5 fires at M as well** — see its own section for why).
- advanced.md §A2 (stuck playbook) and §A3 (checkpoint) are Phase 2 events, not scale gates — they can fire at any scale; open them when they fire, not before.
- **loop.md §L0 is read at every scale**, before any of the above: it decides whether this file's Phase 2 runs at all. The rest of loop.md opens only on the route it belongs to. A `loop`-routed task skips `#build-debug` and comes back here for `#acceptance-gate`; a `fanout`-routed one does the same.

---

## debate-aggregation

Used in Phase 1 (design). Run only when triage classifies the task as M/L. For S, skip and let the lead design alone.

0. **Fix the canonical data channel** (data/replication tasks only, before design): decide the primary sources the deliverable must ground on and the "non-degrading way to read them," and record them in the TaskPacket `canon` field (protocol.md §2). Retrofitting this after design or acceptance leads the implementation worker to fill it via a degraded path (image OCR only, eyeballing a screenshot), creating gaps (a real-task defect root cause). Propagate `canon` into every subsequent implementation/repair TaskPacket. Non-data tasks skip this step.
1. **Parallel launch**: once user Q&A via superpowers:brainstorming is done, and **before** the lead writes its own proposal, dispatch the identical DesignPacket request (TaskPacket, out_schema=DesignPacket; protocol.md §2) to SOL+agy simultaneously via `run_in_background`.
2. **Anchoring-avoidance barrier**: the lead writes its own proposal (a DesignPacket) to completion without reading the external responses. Ordering is guaranteed by procedure, not code — place the actions that wait for or check the external output after the lead's proposal is complete. **But "do not read it" is not achievable once a reply is in flight**: a completion notification carries the channel's stdout into the lead's context unbidden, mid-sentence, and an external DesignPacket that has been read cannot be unread. So make the barrier physical — redirect each launch into `.babel/<task>/results/design-<channel>.raw` (`agyask … > …` / `solask … > …`), exactly as Phase 3 lands acceptance results in files, so the notification carries nothing. If a launch template is used unredirected, dispatch the externals *after* the lead's own DesignPacket is written instead; the parallelism is worth less than the independence it would cost.
3. **L only**: within Claude, generate independent per-viewpoint designs (MVP-first / risk-first / user-first) as a mixed Sonnet/Opus generation via the Workflow tool's `parallel()` (blueprint uses the same `agent()` API as the acceptance-gate template; schema is DesignPacket).
4. **Integration**: consolidate all proposals (own + SOL + agy + Claude-internal viewpoints) into an agreement matrix plus points of difference.
5. **Resolving differences**: the lead first fills cross-system differences with grounding (primary sources / actual code). Dynamic arbitration to the domain-strongest model (algorithmic→SOL / API spec→agy, sending only the differences) is in `advanced.md` §A4. If differences cannot be filled, the lead reconsiders at maximum depth (SKILL.md "think at maximum depth when stuck") → if that still fails, user gate "design differences."

### SOL launch command template

Write the payload to `.babel/<task>/inbox/design-req.json` and have SOL read it via `--cwd` (protocol.md §3, to avoid the argv limit). Do not use protocol.md pointers with SOL; embed the output format inline each time (protocol.md §11).

```bash
grep -rnEi 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|(api[_-]?key|secret|password|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_/+=-]{16,}' .babel/<task>/inbox/design-req.json .babel/<task>/spec.md && { echo 'secret pattern in the design payload — mask before dispatch (protocol.md §0)' >&2; exit 1; }
solask --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/design-req.json. Read it and referenced files. Output DesignPacket JSON only: {approach:str, decisions:[str], risks:[str], tradeoffs:[str], rec:str}. Example: {\"approach\":\"JWT rotation via refresh token\",\"decisions\":[\"15min access TTL\"],\"risks\":[\"clock skew\"],\"tradeoffs\":[\"extra round trip\"],\"rec\":\"adopt\"}. No prose outside JSON." > .babel/<task>/results/design-sol.raw 2> .babel/<task>/results/design-sol.err
```

- `--tier normal` (normal for design, deep for diagnosis/critical acceptance).
- `run_in_background: true`, with Bash `timeout: 600000` for the foreground case only — a backgrounded job ignores it and is bounded by solask's own ~9 min cap (protocol.md §8). Wait for the completion notification together with agy's.

### agy launch command template

agy is sent inline payloads only (protocol.md §1) → do not reference a path to spec.md; inline the spec essentials (goal/criteria/constraints) into the prompt. Build the prompt with the Write tool and dispatch it with `agyask "$(cat <file>)"` — never a heredoc (protocol.md §3). Keep the payload to the diff-hunk equivalent only, under the 32 KB cap.

Write this to `.babel/<task>/inbox/agy-design.txt` with the Write tool (not a heredoc — protocol.md §3):

```
TaskPacket: {"goal":"independent design for <task summary>. Spec essentials: <summarize spec.md's goal/criteria/constraints inline here>","files":[],"inputs":[],"criteria":["<acceptance criteria>"],"constraints":["<constraints>"],"out_schema":"DesignPacket"}
Output DesignPacket JSON only, no prose. Do not use any tools — answer directly from the text given above.
```

```bash
[ "$(wc -c < .babel/<task>/inbox/agy-design.txt)" -lt 32768 ] || { echo 'over the 32 KB cap — split or drop agy (protocol.md §3)' >&2; exit 1; }
grep -nEi 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|(api[_-]?key|secret|password|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_/+=-]{16,}' .babel/<task>/inbox/agy-design.txt && { echo 'secret pattern in the design payload — mask before dispatch (protocol.md §0)' >&2; exit 1; }
AGY_PRINT_TIMEOUT=180s agyask "$(cat .babel/<task>/inbox/agy-design.txt)" > .babel/<task>/results/design-agy.raw 2> .babel/<task>/results/design-agy.err
```

Bash `timeout: 200000` applies only if run in the foreground; backgrounded, the bound is `AGY_PRINT_TIMEOUT` enforced by the agyask watchdog (protocol.md §8).

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

## loop-engineering

Replaces Phase 2 when Phase 0.5 routes `loop` → `loop.md` §L1-§L8. The charter gate (§L1) fires **before** any implementation work; the iteration (§L4) generates one candidate per channel blind and in parallel and lets the oracle select, so there is no merge and no adjudication in this phase — the whole reason a loop can afford three generators when an acceptance round can barely afford three reviewers.

Two things route back into this file. The winner still runs `#acceptance-gate` at the task's scale — a measured candidate has not been reviewed on any of the four dimensions. And a loop that stalls goes to `#sequential-switching` before its user gate, with the whole candidate history (`state.json.loop.candidates`, each with the cascade stage it died at) as the input that a stuck Phase 2 usually lacks.

---

## workflow-fanout

Proposed, never launched, when Phase 0.5 sees the shape → `loop.md` §L9. The proposal is the deliverable: the enumerated work-list, its size, per-item and total cost, whether worktree isolation is needed, and the shape (`pipeline()` unless a stage genuinely needs every prior result at once). babel's crew approval is not the `Workflow` tool's opt-in, and reading it as one launders a gate that exists deliberately. Accepted, it replaces Phase 2 and the result still comes back here for `#acceptance-gate`; declined, the task runs `linear` and the lead says what that costs instead.

---

## acceptance-gate

Phase 3 by scale: **S = one adversarially-prompted Claude reviewer** — a single Agent covering all four dimensions, *not* the (a) Workflow (no Opus verify stage, no script); skip the rest. SOL is not dispatched for S acceptance at all (SKILL.md Phase 0): small diffs raise SOL false positives, and S has no second track to catch them. **M = one (a)(b)(c) round**, lead merge, and C/H fixes; no step-5 loop, convergence check, or completeness critic. After an M fix, re-run one change-impact reviewer whose scope intersects the fix and reported the finding; prefer SOL when several qualify. **The M re-review payload is not an A1 delta** — M's state has no cursors or snapshots (SKILL.md Phase 0 shapes). Rebuild the changeset diff for the fix's paths only (`git diff <baseline-commit> -- <paths>`, minus baseline hunks as above, **plus `git diff --no-index /dev/null "<path>"` for any fixed path that is untracked** — exactly as the main changeset build does, since a task-created file emits nothing from `git diff` against the baseline commit) and send that; it is slightly wider than a true delta and needs no multi-round machinery. That re-review fires **exactly once**: fix any new C/H it returns, then stop. It is still a dispatch, so it takes the next `round` index and writes `results/<agent>-r<N>.jsonl` under it (protocol.md §5, write-once) — M has no loop, but it does have two rounds' worth of result files. M has no loop, so anything still open after that fix goes to the user as residual risk (user gate) rather than into another round — otherwise the re-review is an unbounded loop wearing M's clothes. **L = full section.** See SKILL.md Phase 0.

**Review target = the actual changeset at the start of Phase 3**, not the file list estimated during Phase 0 triage — if an out-of-scope shared module was touched during implementation, include it too (agy review #8).

**The task delta, precisely.** Phase 0 records a baseline in `state.json` as `"baseline":{"commit":"<git rev-parse HEAD>","dirty":["<paths already modified before babel started>"]}`, plus `.babel/<task>/baseline.diff` holding those pre-existing hunks verbatim when `dirty` is non-empty. The Phase 3 changeset is everything that changed since that baseline **minus** that pre-existing work — reviewing the user's unrelated work in progress wastes a round and produces findings nobody asked for.

Subtract at hunk granularity, not path granularity. A path in `dirty` that the task never touched drops out whole; a path in `dirty` that the task *did* edit stays in, with the hunks already present in `baseline.diff` excluded — dropping the whole file instead would hide the task's own edits to it, which is the worse of the two errors. Exclusion means exact-match: a current hunk identical to a `baseline.diff` hunk drops out; a current hunk that overlaps a baseline hunk but no longer matches it (the task edited the same region the user had touched) **goes in whole, deliberately** — the two authors cannot be separated inside one hunk, and hiding the task's edit is the worse error, same rule as the untracked-edited case below. Note it in the acceptance report so findings against the user's lines are not read as findings against the task.

Build it so nothing is silently dropped: `git diff <baseline-commit>` covers tracked edits **including staged ones**, and `git ls-files -o --exclude-standard -z` names untracked files, which a plain diff omits entirely — a new file is exactly where a fresh defect hides. Write the unified diff to `.babel/<task>/inbox/changeset.diff`, appending each untracked file with `git diff --no-index /dev/null "$p"`. **Read that list NUL-delimited and quote every interpolated path** — without `-z`, git C-quotes names containing spaces, quotes, newlines or non-ASCII, so the shell receives escape sequences as literal bytes and quoting alone does not recover the real name; either way the file's hunks then never reach a reviewer while the round still counts as reviewed:

```bash
git ls-files -o --exclude-standard -z | while IFS= read -r -d '' p; do
  git diff --no-index /dev/null "$p" >> .babel/<task>/inbox/changeset.diff
done
```
 and the file list to `.babel/<task>/inbox/changeset-files.txt`. On a multi-round L run, also copy each changeset file verbatim to `.babel/<task>/snap-r<N>/<repo-relative-path>` at dispatch — the snapshots the inter-round delta is built from. How the per-channel delta is built, named, and sent (laggard channels, added/deleted paths, the diff-of-diffs trap) is defined once in `advanced.md` §A1; the state fields it reads are `protocol.md` §5. Reviewers that can read the fs (SOL / Claude subagents) receive diffs by path; agy receives the hunks inline.

**Assert the payload before dispatching it.** Every "clean" verdict this gate can produce is a statement about the bytes that were actually sent, and nothing downstream re-derives them: a `NONE` from a channel handed a 0-byte diff is indistinguishable from a `NONE` from a channel handed the real changeset. So gate the build, and record what was sent:

```bash
D=.babel/<task>/inbox/changeset.diff
[ -s "$D" ] || { echo 'changeset is empty — the round is void, not clean (protocol.md §4)' >&2; exit 1; }
# Changed text lines = args.diffLines. Ask git, do not pattern-match the diff:
# a removed source line reading "-- value" renders as "--- value" and a naive
# header subtraction eats it, while `^[+-][^+-]` drops a legitimate `+++i`.
# Either way the count is wrong and the reviewer bracket is picked too small.
# `git apply --numstat` reads the dispatched payload itself, so the count matches
# what the reviewers actually get (baseline hunks already subtracted, untracked
# files already appended). Binary files report "-" and contribute 0, which is
# exactly the void-round signal below.
lines=$(git apply --numstat "$D" | awk '{a+=$1+$2} END{print a+0}')
[ "$lines" -gt 0 ] || { echo "void round: changeset has 0 reviewable text lines (binary-only?) — report as void, do not dispatch" >&2; exit 1; }
```

**Then mint a receipt marker pair per channel and plant it in that channel's own copy
of the payload** (protocol.md §2). One shared copy cannot carry per-channel tokens,
and a shared token is one a channel can copy from a sibling's answer, so each channel
gets its own file — the bytes above the token line are identical, so this costs a `cp`:

```bash
: > "$TOKENS"          # per round, never appended across retries: a stale token from
                       # an earlier attempt would still validate a replayed response
CHANNELS='<claude | claude sol agy>'   # placeholder like <N>: S = claude only; M/L = all three (SKILL.md Phase 0)
for ch in $CHANNELS; do
  # Round 1 dispatches the changeset; from round 2 each channel gets its OWN delta,
  # so resolve $SRC per channel. A constant here is the defect A6's header warns
  # about in the other direction: every channel silently re-reviews round 1.
  SRC="$D"                                     # round 1
  [ "<N>" -gt 1 ] && SRC=$(ls ".babel/<task>/inbox/delta-r<N>-$ch.diff" \
                              ".babel/<task>/inbox/delta-r<N>.diff" 2>/dev/null | head -1)
  [ -n "$SRC" ] || exit 1
  P=".babel/<task>/inbox/changeset-r<N>-$ch.diff"
  # `|| exit` is load-bearing: on a failed copy the appends below still succeed and
  # create a file whose only lines are tokens, so the channel receives an empty
  # payload it can produce a perfect receipt for — the void round the receipt exists
  # to expose, reintroduced by the stamping step itself. Measured: without it, a
  # missing $SRC yields a 1-line payload and a valid token.
  cp "$SRC" "$P" || exit 1
  # A diff whose last line is "\ No newline at end of file" has no trailing newline,
  # and the append would then land on that line instead of its own.
  [ -z "$(tail -c 1 "$P")" ] || printf '\n' >> "$P"
  # TWO tokens, at opposite ends. One at the end alone is satisfiable by reading the
  # last line — `tail`, or an LLM's final-chunk read — which is not review. Requiring
  # a marker from the first quarter AND one from the end means neither end alone
  # produces a valid receipt. This raises the floor; it does not prove comprehension.
  a="r<N>-$(openssl rand -hex 4)"; b="r<N>-$(openssl rand -hex 4)"
  q=$(( $(wc -l < "$P") / 4 + 1 ))
  awk -v n="$q" -v t="$a" 'NR==n{print "babel-receipt-token-a: " t} {print}' "$P" > "$P.tmp" \
    && mv "$P.tmp" "$P"
  printf 'babel-receipt-token-b: %s\n' "$b" >> "$P"
  [ "$(wc -l < "$P")" -gt 2 ] || exit 1                 # payload is more than the tokens
  # Store the token HASHES, never the tokens. SOL runs outside the sandbox, so an
  # answer key in a predictable path — `.babel/`, /tmp, anywhere — is a cheaper way
  # to pass the gate than reading the payload. A hash validates a response and
  # discloses nothing to whoever finds the file.
  printf '%s %s %s %s\n' "$ch" \
    "$(printf '%s' "$a" | shasum -a 256 | cut -c1-16)" \
    "$(printf '%s' "$b" | shasum -a 256 | cut -c1-16)" \
    "$(shasum -a 256 "$P" | cut -c1-16)" >> "$TOKENS"   # 4th field = args.digest (§A6)
  # Secret scan before anything external reads it (SKILL.md Safety, protocol.md §0).
  # A hit stops the dispatch; mask or drop the hunk and tell the user what was withheld.
  grep -nEi 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|(api[_-]?key|secret|password|token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_/+=-]{16,}' "$P" \
    && { echo "secret pattern in $P — mask it before dispatching $ch" >&2; exit 1; }
done
```

`TOKENS` holds **hashes, not tokens**, and lives outside the repository —
`TOKENS="${TMPDIR:-/tmp}/babel-<task>-r<N>-tokens.txt"`. Both halves matter and
neither is sufficient. Outside the repo, because SOL is dispatched with
`--cwd "<repo>"` and can read anything in it. Hashed, because `solask` also runs
**outside the Claude Code sandbox**, so "outside the repo" is not out of reach — the
path is derivable from the task slug and round, and a plaintext list anywhere on the
filesystem is a cheaper way to pass the gate than reading the payload. A hash
validates a response and gives whoever finds the file nothing. Regenerated every
round, so losing it costs one re-dispatch.

The tokens sit at **opposite ends** of the payload, and both are required. One token
at the end is satisfiable by reading the last line — `tail`, or a model's final-chunk
read — which is exactly the non-review the receipt exists to catch; a marker in the
first quarter plus one at the end means neither end alone produces a valid receipt.
Neither is ever repeated in the prompt — the prompt says only where to find them
(protocol.md §2), and a template that inlines one for convenience converts the receipt
back into a formality. **Stated plainly: this bounds the cheapest lazy behaviours, it
does not prove the payload was understood.** A channel that greps both markers still
passes. What catches that is grounding, and the silence rule for a channel that never
produces a groundable finding. The payload digest recorded as the 4th field is taken
**after** both appends, so it covers the exact bytes that channel receives, and it is
what `advanced.md` §A6 takes as `args.digest` for the Claude track.

Validate every response against this file before ingesting it (protocol.md §7 receipt
ingestion gate): wrong token, absent token, empty `paths` → channel failure, re-request
once, then degrade the track for the round. **A `NONE` with no valid receipt is not a
clean result at any scale** — this is the gate that makes a lazy round and a clean
round distinguishable, and it binds at S too, where there is no second reviewer and no
critic to catch a channel that reviewed nothing.

Binary paths contribute 0 to this count without making it 0, so a changeset of one
text edit plus one changed binary passes the gate while the binary goes unreviewed —
reviewers see only "Binary files ... differ". Enumerate every binary path in the
dispatch record as an **uncovered artifact** and carry it into the acceptance report
as residual risk; a round covering only the text half is not a clean round for the
whole changeset.

Three ways this comes back zero, all of which otherwise read as a clean round: the task genuinely changed nothing; the write failed or `.babel/` was wiped between build and dispatch; or the changeset is real but has no reviewable text (binary blobs, `Binary files … differ`). The first is "nothing to review" and the gate does not run at all. The other two are **void rounds** — report them as such, never as convergence. Write the byte count and the changed-line count into the dispatch record, and treat any channel's `NONE` against a payload of 0 bytes as a channel failure (protocol.md §4). For spec-compliance review, distribute `.babel/<task>/spec.md` the same way (inline the essentials for agy).

### Procedure

1. Fix the changeset and dispatch the 3 systems.
   - (a) Claude adversarial Workflow: generate/run the script below. Adversarial verification is L-only; M uses parallel Agents without Opus adjudication. **L fold prior**: (a) starts folded at one agent regardless of diff size (measured prior, `advanced.md` §A9) unless it is the only track, and **stays folded on every subsequent L round until it has earned a grounded `confirmed`** — the prior sets the starting width, the fold-reversal rule ends it, and neither is scoped to round 1 alone. Otherwise scale reviewers by changed lines — the four dimensions are always all covered, what changes is how many agents share them:
     - **under 50 lines → 1 agent** carrying all four dimensions in one prompt (pilot 1 showed 3 reviewers excessive for 44 lines);
     - **50-200 → 2 agents**: `correctness + edge-cases` / `security + spec-compliance`;
     - **over 200 → 3 agents**: `correctness` / `security` / `edge-cases + spec-compliance`.
     Do not hand-set the grouping in the template: pass the measured **changed-line count** (added+removed, not the diff file's `wc -l` — context lines inflate it 2-3×) as `args.diffLines` and A6 selects the bracket itself (it is not fixed at four agents). Pass `round`, `digest` and `receiptTokens` from the payload step too — the digest is what keeps a resumed run from replaying findings against a rebuilt payload, and the marker pair is what the receipt gate checks (`advanced.md` §A6).
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

(c) SOL: write the TaskPacket to `.babel/<task>/inbox/accept-r<N>.json` (argv avoidance, protocol.md §3) and point SOL at it. **Round 1 names the changeset; from round 2 on, SOL's own delta** — but always the token-stamped per-channel copy the payload step wrote (`changeset-r<N>-sol.diff`, built from `changeset.diff` on round 1 and from `delta-r<N>.diff` or its `-sol` variant after that) — since re-sending the whole changeset re-reviews what it already cleared. The exception is a channel with no `last_seen`, one that has never returned a clean result: it has no snapshot to diff from and gets the full changeset regardless of round (`advanced.md` §A1). Same for (b) agy below, and for the Claude template (`advanced.md` §A6). The packet must name the diff itself, and **no path list at all** — SOL runs backgrounded for up to ~9 minutes while the lead keeps fixing C/H from the in-session track, so any path it resolves is read from whatever the tree holds at that moment, not from what was dispatched. The finding then cites moved or already-closed lines, grounds as `refuted`, and A9 demotes the channel for a race the lead caused. Keep `inputs` empty; everything SOL needs is in the diff:
```json
{"goal":"full review of changeset",
 "files":[{"path":".babel/<task>/inbox/changeset-r<N>-sol.diff"},{"path":".babel/<task>/spec.md"}],
 "inputs":[],
 "criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
```
```bash
solask --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/accept-r<N>.json. Read it and the referenced files. First line of your answer is the receipt: {\"receipt\":{\"tokens\":[\"<the value on the babel-receipt-token-a line, somewhere in the first quarter of the diff>\",\"<the value on the babel-receipt-token-b line, the diff's last line>\"],\"paths\":[\"<files you actually read>\"],\"dimensions\":[\"correctness\",\"security\",\"edge-cases\",\"spec-compliance\"],\"unread\":[\"<dispatched paths you did not read>\"]}}. Then output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence ~10-25 words>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) after the receipt line if clean — the receipt is required either way. No prose." > .babel/<task>/results/sol-r<N>.raw 2> .babel/<task>/results/sol-r<N>.err
```
`run_in_background: true` (bound = solask's ~9 min cap, not the Bash `timeout: 600000`; protocol.md §8). For critical acceptance of a security/irreversible L task, swap in `--tier deep` (see the cost discipline in SKILL.md).

(b) agy: pass the changeset's diff hunks inline, and include the finding-jsonl format line plus one example line in the prompt (inline, like SOL). Check the payload against the 32 KB cap before dispatch; over it, split the hunks or degrade (protocol.md §3).

**Build the prompt with the Write tool, never with a shell heredoc** (protocol.md §3). Write this to `.babel/<task>/inbox/agy-r<N>.txt`:

```
TaskPacket: {"goal":"full review of changeset","files":[{"path":"<diff hunk summary>"}],"inputs":[],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Diff hunk: <the changed diff hunks, carrying agy's babel-receipt-token-a line in their first quarter and its babel-receipt-token-b line as the block's last line>
First line of your answer is the receipt: {"receipt":{"tokens":["<the value on the babel-receipt-token-a line in the first quarter of the hunk block above>","<the value on the babel-receipt-token-b line at the end of that block>"],"paths":["<files the hunks came from that you reviewed>"],"dimensions":["correctness","security","edge-cases","spec-compliance"],"unread":["<hunks you did not review>"]}}
Then output one JSON array per line: ["<id>","<sev C|H|M|L>","<file>",<line>,"<claim>","<evidence ~10-25 words>"]. Example: ["F1","C","auth.py",42,"token expiry unchecked","verify_token() decodes JWT without checking exp claim"]. Output NONE (single word) after the receipt line if clean — the receipt is required either way. No prose. Do not use any tools — answer directly from the text given above.
```

agy's markers go inside the **inlined hunk block**, not in a file it cannot read
(protocol.md §1) — which unavoidably puts them in the prompt. That is the documented
inline exception (§2), and it is weaker: it evidences reading the block, not opening a
file. Do not read agy's `paths` as file access. When a round is split into parts (§3),
each part carries **its own pair** and is validated separately; a part whose receipt
fails is a failure of that part, and the round's agy coverage is the parts that passed.

then dispatch it:

```bash
[ "$(wc -c < .babel/<task>/inbox/agy-r<N>.txt)" -lt 32768 ] || { echo 'over the 32 KB cap — split or drop agy (protocol.md §3)' >&2; exit 1; }
AGY_PRINT_TIMEOUT=240s agyask "$(cat .babel/<task>/inbox/agy-r<N>.txt)" > .babel/<task>/results/agy-r<N>.raw 2> .babel/<task>/results/agy-r<N>.err
```
`run_in_background: true` with `AGY_PRINT_TIMEOUT=240s` — a whole-changeset review is heavier than a design request, so agy's budget is intentionally extended. **Both streams are redirected in every template above.** stdout is the findings channel and stderr carries the one `BABEL_USAGE` line the scoreboard's `tokens` field is filled from (protocol.md §5); a template that redirects only stdout leaves that field `null` on a shim that is working, which is indistinguishable downstream from no instrumentation at all. That env var is the real bound; the Bash `timeout: 300000` only applies in the foreground (protocol.md §8).

### Merge procedure

0. **Validate every receipt first** (protocol.md §7), reading **only the receipt line** — `head -1` of the channel's `.raw`, never the whole file. The gate is per channel and therefore attributed by construction; opening the findings alongside it hands the lead the finding-to-channel mapping before step 0b can withhold it, and there is no unreading it. A track whose receipt fails contributed no reviewed bytes: its lines are not merged, its entry is written with `receipt` set and `grounded:[]`, and its dimensions count as uncovered for the round's convergence test. Merging a response before checking its receipt is how an unread payload enters the round as findings.
0b. **Source-delayed pool (M/L only)**: build the merge input with a command, not by reading each channel's file in turn. Concatenate the receipt-passing channels' finding lines, tag each line with an opaque per-round id, shuffle, and write the id→channel mapping to a **separate** file:
   ```bash
   R=.babel/<task>/results
   # PASSED is set by step 0 and holds ONLY the channels whose receipt validated.
   # Never a hardcoded channel list: a failed-receipt track contributed no reviewed
   # bytes (step 0) and a routing-skipped one was never dispatched, and either one
   # entering the pool is a finding merged from a channel that reviewed nothing.
   # Set by step 0, above. Not a default: an unset PASSED must stop the merge, not
   # quietly become a full channel list that pulls in whatever result files exist.
   : "${PASSED:?step 0 must set PASSED to the receipt-passing channels for this round}"
   : > $R/r<N>-srcmap.txt
   i=0; for ch in $(printf '%s\n' $PASSED | sort -R); do
     f=$R/$ch-r<N>.jsonl                     # the per-agent results file (protocol.md §5)
     [ -s "$f" ] || continue
     i=$((i+1)); printf 'X%s %s\n' "$i" "$ch" >> $R/r<N>-srcmap.txt
     # `/^\[/`, not `NR>1`: a finding line is a JSON array, so this drops the receipt
     # line AND the bare `NONE` of a clean channel, which NR>1 would tag and feed into
     # dedup as if it were a finding. Tag and line are TAB-separated and the line
     # itself is left byte-identical — prefixing it inline would make it invalid JSON.
     awk -v s="X$i" '/^\[/{print s"\t"$0}' "$f"
   done | sort -R > $R/r<N>-pool.jsonl
   ```
   The pool is `X<i><TAB><finding-json>` per line; split on the first TAB to parse. **Measured**: this block was run over a three-channel fixture (two channels with findings, one clean) under both `/bin/sh` and `dash` — receipt lines and the bare `NONE` are dropped, tags are TAB-separated, `srcmap.txt` is written in shuffle order, the shuffle differs between runs, and an unset `PASSED` stops the merge with a non-zero status. A channel that passed its receipt but reported nothing still takes an `X` id in `srcmap.txt` and contributes no pool line; that is a gap in the id sequence, not a defect. Read `pool.jsonl` for steps 1–2 and for the protocol.md §4 severity re-assignment; do not open `srcmap.txt` until step 3. The dedup class's **member ids are recorded here** and only mapped to channels at step 3, so nothing A9 needs is lost by waiting — but note what does not survive the wait: `by` is a set of *channel names*, and the mapping is one-way, so a class must carry its `X` ids forward rather than a bare count. A count cannot be re-attributed after the fact, and the pair that missed together is precisely what a count cannot express (`advanced.md` §A9, scope split). At **S** this is skipped: one reviewer, nothing to delay.
   **This only works if every track lands in a file.** An in-Claude reviewer's answer returns as the agent's own result and arrives in the lead's context already labelled with which agent produced it — there is no delaying that after the fact. So instruct in-Claude reviewers to **write** their receipt and finding lines to `$R/<agent>-r<N>.jsonl` and return only a one-word completion marker. A round that skipped this has a source-delayed pool over its externals and an attributed (a) track, which is worth saying in the acceptance report rather than describing the round as delayed.
   **What this is and is not.** It is *source delay*, not anonymity. The lead runs the shuffle itself, so nothing physically stops it from reading the mapping; what changes is that doing so is a deliberate extra action that leaves a trace, the same standing the grounding record's own ceiling has (protocol.md §7). It is also defeated by style — a channel's phrasing is often recognisable, so the label goes and the tell does not. And the motivation is N=1: on one instrumented run agy under-declared severity twice against SOL on the same defects (H→M, M→L). Cheap enough to keep at that evidence level; not strong enough to describe as blinding.
   Check that this is wired correctly rather than merely written down: run a merge over a fixed two-channel fixture, then swap the two channels' mappings and re-run. The post-step-2 severities and fingerprints must be identical across both runs, and the restored `by` attribution must follow the swap.
1. **Fingerprint dedup**: match on `{path, symbol (function name / spec section ID), violated invariant}`. Do not use line numbers in the dedup key (protocol.md §7). Matching is a semantic comparison by the lead. **Record each dedup class's member ids** on every member — the **anonymized** `X<i>` ids, because that is all step 1 has: `srcmap.txt` stays closed until step 3, so channel identity is not available here. Step 3 maps them to `by` (the channel names) the moment it restores attribution — it is what A9's duplicate split reads (§A9), and it is only knowable here, before the class collapses into one finding.
2. Match against **both** the already-reported and already-rejected lists (prevents re-surfacing loops).
3. **Restore attribution here** (read `srcmap.txt`) — this is where each dedup class's `X` ids from step 1 become its `by` set (protocol.md §5), and it is the earliest point at which they can — before anything channel-conditional runs — the SOL-small-diff rule immediately below, `channel_scoreboard` entries, `by` credit, and step 5's routing all need identity, and every one of them sits at or after this point by design. Then verify C/H only: batch 8–12 surviving findings per call. **The (a) track's verifier-rejected C/H arrive here, not deleted** (`advanced.md` §A6 returns `rejected` in full): ground every rejected **C** unconditionally, read every rejected **H** against the code rather than inheriting the verdict, and list whatever you do not ground in the acceptance report as *verifier-rejected, ungrounded*. Reviewer and verifier share a model family; a rejection is one family's reading, and the round it silently cleans is the one nothing downstream can detect. If a repro can run, verify with the reproduction command / failing test; if not, substitute an invariant argument (protocol.md §7, same section for repro safety rules). **A new C/H here that cites lines the previous round's fix wrote is an A10 P4 record** — append it to `.babel/process-failures.jsonl` (lead only) against `fixes/r<N-1>.diff` from step 4; the intersection is at line granularity, which step 5's path-level routing does not compute.
   **`accessBlocked` is not `rejected` and not `unresolved`** (`advanced.md` §A6): the verifier obeyed the access list and declined to open a credential-bearing path, so it never ruled. Do not ground these by opening the cited path — that is the one thing the access list exists to prevent, and the lead is not exempt from it. Judge each on the finding text and whatever the changeset itself shows, then list them in the acceptance report as *unresolved-by-access*, naming the path. They cost no channel a retry and enter no scoreboard record.
   **Ground SOL findings on small diffs**: under 50 lines, SOL acceptance has more false positives (pilot 1 reported nonexistent trailing whitespace). Before adopting an SOL-only finding, confirm actual file lines; multi-system agreement may raise priority. (S acceptance dispatches no SOL — SKILL.md Phase 0 — so this applies to SOL's checkpoint and M/L acceptance findings, not to any S review.)
4. Fix verified findings only. **Re-ground before repair** against primary sources (`canon` / actual file line) and confirm the premise; never trust an audit finding as-is. This is a premise re-check against the file as it stands now — an earlier fix may have moved or already closed it — not a second grounding event: the finding keeps the one `confirmed`/`refuted` label step 3 gave it, and nothing is appended to `channel_scoreboard` here (protocol.md §7, "each is grounded once"). Pilot 2's R4 re-grounding prevented 2 false detections. Every repair TaskPacket must include constraint: `before fixing, re-ground against canon and confirm the finding's premise.` **After the round's fixes are applied, write `git diff` for exactly the fixed paths to `.babel/<task>/fixes/r<N>.diff`** — the per-round fix hunks A10's P4 record point intersects the next round's findings against. Nothing else persists them: step 5's routing works at path granularity, so without this the record point is prose with no input.
5. Re-run with **change-impact routing**: re-dispatch only the reviewers whose previous scope or unresolved findings intersect the fixed file/function (not unrelated reviewers). Previous scope is the receipts' `paths`, not the dispatched scope — what a channel was sent and what it read are now separately recorded, and routing wants the second. **For L multi-round, further narrow crew composition with `channel_scoreboard`** (protocol.md §5) — drop from the next round any channel with confirmed=0 and refuted≥2 over the last 2 rounds, or any channel silent (zero C/H emitted; `emitted` counts every severity — advanced.md §A9) on 2 rounds where another channel earned a grounded `confirmed` over the same scope (within-task online adaptation, `advanced.md` §A9). Each grounding **record** — outcome plus the check that produced it, `class`, and `by` — is appended to the scoreboard at this merge stage (lead exclusively), written as the check runs. A record with no `check` is not a grounding event and must not be written (protocol.md §5): that field is the only thing separating a lead that ran the repro from a lead that agreed.
6. Output M/L in line form like C/H, but do not verify or fix them. Present them to the user in the final report.

### Termination condition

- **Convergence**: a round with zero new C/H is a *candidate* clean round, not convergence. At **M and L**, run the completeness critic (`advanced.md` §A5) after it and converge only if the critic is empty too. This holds for round 1 as well — a clean first round is the case where an uncovered dimension is most likely to be the reason nothing was found.
- **One off-axis dispatch before converging** (M and L). The four dimensions are the axes a delta round rides, and a changeset that has survived several of them has been examined from four directions and no others. So before declaring convergence, dispatch one external round that names those four as **out of scope** and asks for the angles nobody thought to look from — second-order effects on the protocol's other rules, what the mechanism teaches the lead to do, incentives and who benefits, what rots first, the mechanism's own trust status, what the design forecloses. Seed a few directions and say to prefer an unlisted one. A finding here may be a consequence, an incentive, or a claim the docs cannot support; it does not have to be a defect in code, and severity is by what it would cost to discover later. Measured: on the run that produced this rule, the off-axis dispatch found that a mechanism could not fire for the one case it existed for — after eight in-scope rounds and a completeness critic had all passed over it. It is expensive (deep tier, most of a million tokens there) and it is one dispatch, not a loop. **Mechanically it is an ordinary acceptance dispatch** — the same template, receipt pair, redirects and §7 gate as any other round; only the prompt's body differs, and `dimensions` in the receipt reads `["off-axis"]` so the scoreboard does not record it as coverage of the four.
- **Stop on residual risk, not on the finding rate.** Before dispatching another round, write two lines: **what is still uncovered** (areas no reviewer has read this task, claims asserted but never executed, dimensions a dead channel took with it) and **what the round is estimated to cost**. Converge when the residual does not justify the spend, and say so in the acceptance report rather than letting the round counter decide. The counters below bound a runaway; they do not measure whether the next round is worth buying, and a rule that reads only the finding rate will keep buying rounds as long as findings keep arriving — which is exactly what a review of the previous round's fixes will always produce. Measured on the run that produced this rule: rounds 4-8 all landed inside one bullet of one file, each locally justified as "the last round's fixes are unreviewed", together an order of magnitude over the estimate given at the crew proposal.
- **Cap — two counters, three distinct triggers.** The hard ceiling is **`round` = 8**; no path extends past it. The user-approval trigger is **`budget.rounds_consumed` = 4**: before dispatching a round while `rounds_consumed` is already 4, ask, with the added token estimate attached (SKILL.md Phase 0 states the same trigger in the same words). **A round on which new C/H decreased consumes nothing** — trending toward convergence is not the failure mode either trigger exists for; a flat or divergent round consumes 1 (protocol.md §5 defines both counters; `round` also names result files and scoreboard entries, which is why it increments every dispatch regardless). **Plus a floor the lead cannot compute away: ask before dispatching round 5 (`round` = 5) regardless of `rounds_consumed`.** "New C/H decreased" is derived from the lead's own semantic dedup calls, and stopping to ask is a cost to the lead, so the consumption rule alone leaves the only brake on eight rounds of spend in the hands of the party that pays for pulling it — and a finding stream that merely trickles down (20, 19, 18…) consumes nothing forever. Under the floor, a steadily-converging task asks once at round 5 and continues; a thrashing one still asks earlier on the consumed-budget trigger. So a task that converges steadily reaches round 5 before asking, and a task that thrashes asks after its 4th non-progressing round (pilot 2's hard spot: 7 rounds total, under the ceiling, approval obtained on the consumed-budget trigger). At the ceiling, the lead does one final reconsideration at maximum depth, then presents residual findings to the user (user gate "acceptance result" / "residual risk").
- **Crew stretch/shrink for L multi-round**: read the above convergence/extension decisions together with `channel_scoreboard` outcomes — channel dropping, routing weighting, and early folding are scoreboard-driven (`advanced.md` §A9; ephemeral, grounding-driven only, per protocol.md §7 invariant).
