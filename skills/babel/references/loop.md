# babel — route selection and loop engineering

Audience: the lead LLM running babel. This file owns **Phase 0.5** — the decision of *which shape* the task runs in — and the full procedure for one of those shapes, the measured improvement loop.

Read it at Phase 0.5, always: the route decision itself is three predicates and costs almost nothing to evaluate. Read §L1-§L8 only once the route is `loop`; read §L9 only once the route is `fanout`. A task that routes `linear` is done with this file after §L0.

Communication rules → `protocol.md`. Phase procedures for the linear route → `patterns.md`. The bandit and delta machinery this file reuses → `advanced.md` §A1/§A9.

---

## L0. Route selection (Phase 0.5)

**Route is orthogonal to scale.** S/M/L sizes the crew; the route decides what the crew *does*. A loop-routed S task is still 2 members; a fanout-routed L task is still the full 5. Decide scale first (SKILL.md Phase 0), then route, then state both in the one crew proposal — never a second approval gate for the same task.

| Route | The task is | Runs |
|---|---|---|
| `linear` (default) | a change someone can specify | Phase 1 → 2 → 3 as written in `patterns.md` |
| `loop` | a number to move, where nobody yet knows which change moves it | §L1-§L8 in place of Phase 2, then Phase 3 on the winner |
| `fanout` | the same small change across many independent sites | §L9 — propose Claude Code's `Workflow` tool to the user |

### Three things called "loop" — do not confuse them

The word collides three ways, and picking the wrong one wastes the whole task:

- **Loop engineering** (this file): *the model iterates against a measurement.* Many attempts, an automated verdict per attempt, stop on a target. Wall-clock is irrelevant; the loop advances as fast as the oracle runs.
- **`Workflow` fan-out** (§L9): *many agents run once each,* over an enumerable work-list, in parallel. One pass, no feedback between items.
- **`/loop` interval mode**: *one prompt re-fires on a wall-clock schedule* to poll external state that changes on its own (CI, a deploy, a queue). Nothing here is being optimized. If the answer to "what changes between firings?" is "the world, not our code", it is this and babel is not involved.

### The `loop` predicate — all four, or it is not a loop task

1. **Measurable.** The goal reduces to a number or a pass/fail predicate that a command *emits*. Not "make it faster" — `pytest tests/bench.py -q` printing a millisecond figure the lead can parse with a stated expression.
2. **Automatable.** That command runs unattended, hermetically, in bounded wall-clock, with no network flake and no human in the middle. State the measured per-run seconds; an oracle nobody has timed is an oracle nobody has run.
3. **Affordable.** `oracle_seconds × candidates_per_iteration × expected_iterations` fits the budget stated at the crew proposal, with the oracle cost counted *three times over* — the cascade (§L2) runs it on every candidate from every channel.
4. **Search, not specification.** The reason this is not already done is that nobody knows *which* change wins — not that nobody has said *what* is wanted.

**Predicate 4 is the one that actually gets skipped, and skipping it is the expensive error.** A task where 1-3 hold and 4 fails is an ordinary `linear` task that happens to own a good test suite. Looping on it buys nothing: iteration 1 produces the change the lead would have written anyway, and iterations 2..N pay full oracle cost to confirm it. Say "this has an oracle but no search — running it linear" in the crew proposal and route `linear`. The symptom to watch for is a user who can already describe the fix; if they can, there is nothing to search.

If 4 holds but 1 or 2 fails, **do not fabricate an oracle to unlock the route.** A metric invented by the lead to make a loop runnable is a metric nobody has agreed measures the goal, and the loop will optimize it perfectly. Either build the oracle as a `linear` task first and re-route afterwards (say so, and get that split approved), or run `linear`.

---

## L1. The loop charter — eliciting the goal before spending anything

A loop with an underspecified goal does not fail; it succeeds at the wrong thing for its entire budget. So the charter is a **user gate** — the fifth, alongside the four in `protocol.md` §0 — and it fires before iteration 0, at every scale, on every `loop`-routed task.

### How to ask (this is most of the quality)

- **Draft first, then ask for corrections.** Read the repo and fill every field yourself before opening your mouth. Then put the *draft* to the user and ask what is wrong with it. A question the lead could have answered by reading is a question that teaches the user this gate is noise, and the next one gets waved through.
- **One round, one message, at most five questions.** Use `AskUserQuestion` where the answer is a choice among drafted options; free text only for the target value and the invariants.
- **Ask only what changes the loop.** If the answer cannot change which candidate wins, it is not a charter question.
- **Ask the negative question.** One slot is always spent on: *"what would make you say this loop hit its number and still wasn't worth running?"* The answer is where the invariants come from — users list what they want unprompted and never list what they assumed. This is the single highest-yield question in the set, because it is the only one whose answer the lead could not have drafted.

### The charter fields

Write it to `.babel/<task>/loop.md` and treat it as SoT for the run (`protocol.md` §5 one-way discipline). Four fields have no safe default — a wrong value there makes every iteration wrong, so each is confirmed by the user in their own words, never inferred:

| Field | Must contain | Why no default works |
|---|---|---|
| `metric` | the quantity, **the direction**, and the exact expression that extracts it from oracle stdout | "the score" is two numbers on most outputs, and a lead that guesses which one optimizes the wrong one silently |
| `target` | a value and a comparator (`p95 < 120ms`), not "better" | with no stop line the loop runs to the budget by construction, and "improved" is then a statement about when the money ran out |
| `oracle` | the exact command, its cwd, its measured per-run seconds, and its **baseline reading** | see §L2 — a loop that never measured its start cannot report improvement afterwards |
| `invariants` | what stays true regardless of the metric: paths that must not change, tests that must stay green, behaviour that must not move | this is the anti-gaming boundary (§L3) and the user is the only party who can draw it |

And three the lead may draft and have confirmed rather than asked cold: `budget` (max iterations, max oracle runs, token ceiling), `held_out` (§L3), `frozen` (§L2 — defaults to the oracle, its inputs, and every test file, which is usually right and must still be shown).

`metric` and `target` together are the loop's whole objective function. If the user cannot state a target, that is not a charter to complete with a placeholder — it is evidence that predicate 4 failed and the task wants a `linear` route with a review, which is worth saying rather than looping.

---

## L2. The oracle contract

### Baseline, and noise

**Run the oracle twice on the untouched tree before iteration 1.** Record both readings. `spread` = the difference.

This is not ceremony. Every subsequent "improvement" is a comparison against the baseline, and an improvement smaller than `spread` is not an improvement — it is the same measurement taken twice. Without a recorded spread, the loop's stall detector cannot fire (the score keeps "moving"), the winner selection promotes noise, and the final report claims a gain the user cannot reproduce. A loop that skipped this reports a number it has no right to.

For a pass/fail oracle the spread is 0 by construction and the two runs instead prove determinism: two different verdicts on the same tree means the oracle is flaky, and a flaky oracle is not an oracle. Fix or replace it before iterating — a flaky verdict makes candidate selection a coin flip that costs a full iteration to toss.

### Cascade — cheap gates first

Most candidates are wrong, and the full oracle is the expensive way to learn it. Score every candidate through stages of rising cost, stopping at the first failure (the evaluation cascade from AlphaEvolve/OpenEvolve, §L8):

1. **Applies.** `git apply --check` against the iteration's base. A patch that does not apply costs nothing to reject and is the most common failure of a channel that reasoned about a stale tree.
2. **Frozen set intact.** The gate below. This one is a *hard stop*, not a low score — see §L3.
3. **Builds / typechecks / lints.** The repo's own fast checks, whatever a contributor runs locally.
4. **Fast subset of the oracle**, where one exists (a smoke case, one benchmark shape, the first N tests). Reject anything that regresses here.
5. **Full oracle.** Only survivors reach it.

Record which stage each candidate died at. That distribution is diagnostic on its own: everything dying at stage 1 means the context packet is stale, everything at stage 3 means the channels are not being told how the project builds.

### The frozen set — enforced mechanically, never by prompting

The oracle, its inputs, and the tests are the only reason any score means anything. A candidate that edits them has not improved the code; it has moved the finish line. Telling the channels not to do that is not a control — a control is a check that runs whether or not anyone complied.

Record the manifest at iteration 0, **outside** any tree a candidate is applied in — a manifest stored where the candidate can reach it is a record of the oracle that the candidate can edit to match:

```bash
FROZEN=$BABEL/frozen.manifest   # $BABEL = .babel/<task>, never inside the candidate worktree

# The manifest is one line per file under every frozen root, sorted, hashed.
# Enumerate rather than hash the roots themselves: modification, deletion AND
# addition all have to be caught, and only a whole-listing comparison catches the
# third — a candidate that adds tests/conftest.py to monkeypatch the timer has
# modified nothing.
frozen_manifest() {
  t=$1; shift
  for r in "$@"; do
    [ -e "$t/$r" ] || { echo "frozen root missing under $t: $r" >&2; return 2; }
  done
  for r in "$@"; do
    find "$t/$r" -type f -print
  done | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(git hash-object -- "$f")" "${f#"$t"/}"
  done
}

frozen_record() {   # iteration 0, on the pristine tree
  frozen_manifest "$@" > "$FROZEN.tmp" || return 2
  [ -s "$FROZEN.tmp" ] || { echo 'frozen set is empty — an unenforceable oracle' >&2; return 2; }
  mv "$FROZEN.tmp" "$FROZEN"
}

frozen_check() {    # cascade stage 2, on the candidate tree
  [ -s "$FROZEN" ] || { echo 'no frozen manifest — iteration 0 never recorded one' >&2; return 2; }
  frozen_manifest "$@" > "$FROZEN.now" || return 2
  cmp -s "$FROZEN" "$FROZEN.now" && return 0
  echo 'frozen set changed — abort the iteration, do not score it' >&2
  diff "$FROZEN" "$FROZEN.now" >&2
  return 1
}
```

`git hash-object` rather than `sha256sum`/`shasum`: babel already requires git, and those two are not the same command on macOS and Linux. Both sides of the comparison are generated by the same function, so a path containing exotic bytes produces the same manifest line either way.

**A `frozen_check` failure is a user gate, not a score of zero.** Rejecting the candidate quietly and iterating on is the wrong response: the loop has just observed a channel optimizing the evaluator instead of the code, and that fact is worth more to the user than the candidate was. Stop, report which paths moved and which channel proposed it, and let the user decide whether to continue with that channel dropped.

**The lead runs the oracle, from the lead's own copy of the command.** Never a command a candidate wrote, edited, or "suggested a tweak to" — that is executing external output, which `protocol.md` §0 forbids and §7 already spells out for repro commands. The oracle command is fixed at charter time and re-read from `loop.md`, not from anything an iteration produced.

---

## L3. Proxy versus true objective

The oracle is a **proxy**. It is the thing being optimized, and anything being optimized by a capable model will eventually be optimized *as stated* rather than as intended. Benchmarks of exactly this failure on coding agents name two vectors — tampering with the evaluator, and reading the held-out data — and find current frontier coding agents doing both (§L8). babel's answer is one structural rule per vector:

- **Evaluator tampering** → the frozen set (§L2), checked mechanically before every score.
- **Leakage into the metric** → a **held-out oracle**, which the loop never runs per-iteration and which no context packet ever mentions. Charter field `held_out`: a second command (a different test file, a different input set, a later slice of data) that measures the same intent. It runs exactly twice — once at baseline, once on the promoted winner.

Read the two together:

| proxy | held-out | reading |
|---|---|---|
| improved | improved | the loop worked; report both numbers |
| improved | flat | the gain is narrower than claimed; report as such, do not report the proxy alone |
| improved | **regressed** | **stop the loop now** and open a user gate |
| flat | — | stall (§L5) |

The third row is the reward-hacking signature and it is the one condition that **ends** the loop rather than continuing it. Resist the reading that the held-out oracle is simply "a bit different" — that is the reading every gamed run supports, and it is available every time. What earns the benefit of the doubt is a grounded account of *why* the two disagree, produced the same way §7 grounds any finding: a code path and an invariant, or an executed check. Absent that, the honest report is that the loop found a way to move the proxy that does not move the goal.

**Report the proxy and the held-out number together, always** — in the acceptance report and in anything shown to the user. A proxy figure quoted alone is the artifact this whole section exists to prevent.

---

## L4. The iteration — three models as islands, not as voters

This is where the multi-model crew earns its cost, and it earns it differently than it does in review. In Phase 3, the channels disagree and the lead must adjudicate. Here **the oracle adjudicates**: candidates are scored, not argued about. That removes the merge cost that makes multi-model review expensive, which is why a loop can afford three generators per iteration when an acceptance round can barely afford three reviewers.

Each iteration:

1. **Build one context packet** (`LoopContext`, `protocol.md` §2) and send the *same* packet to every channel: the charter, the current base tree pointer, the best-so-far patch **with its score**, the last iteration's scores per channel, and the rejected-fingerprint list. Carrying the best patch and its number forward is what makes three channels compound instead of running three independent single-model loops — it is the prompt-sampler idea from AlphaEvolve (§L8), and it is the difference between an ensemble and three people guessing in separate rooms.
2. **Generate blind and in parallel.** Claude (a Sonnet worker, or the lead at S), SOL, and agy each propose **one candidate diff** against the same base, without seeing the siblings' candidates for that iteration. Same anchoring rule as `#debate-aggregation` and the same-round blindness of `protocol.md` §8, and here it is load-bearing rather than hygienic: three candidates that saw each other are one candidate with three sets of edits.
3. **Isolate.** Candidates touch the same paths by construction, so apply each in its own worktree (`Workflow`'s `isolation: 'worktree'`, or `git worktree add` directly). This is the one place in babel where worktree isolation is not a luxury.
4. **Reject on novelty before spending.** A candidate whose normalized diff fingerprint matches one already in `rejected[]` is dropped at zero oracle cost — the novelty-rejection idea from ShinkaEvolve (§L8), implemented on the fingerprint list `protocol.md` §5 already keeps. Normalize by stripping whitespace and comment-only lines before hashing; a re-proposal with a reworded comment is the same candidate.
5. **Score through the cascade** (§L2). Ties inside `spread` are not ties to break on preference — prefer the **smaller diff**, stated as the rule rather than decided per case, because the alternative is the lead picking its own channel's candidate on a coin flip.
6. **Promote and migrate.** The winner becomes the next iteration's base and its patch + score go into every channel's next context packet. Record the loser patches; they are the diversity the next iteration is drawing from, and deleting them is how a loop collapses onto one line of attack.
7. **Score the channels, with the objective label.** Append the iteration to `channel_scoreboard` exactly as an acceptance round would (`protocol.md` §5), with a grounding record per candidate carrying **`method:"oracle"`** — `check` = the oracle command the lead ran, `result` = the measured delta against the base, `at` = the candidate patch path. This is a strict instance of §7's "the verifier executes, not opines", not a loosening of it: an oracle run is an executed command with a recorded result, which is what `repro` already means. It is *stronger* evidence than an acceptance round produces, because the verdict is a number nobody argued for.

That last point makes the existing bandit (`advanced.md` §A9) work here unchanged and better: a channel whose candidates never survive the cascade is folded on measured reward rather than on the lead's impression of it. Fire it under the same condition — **multi-iteration only**, ≥3 iterations expected; below that it is noise. Do **not** drop a channel to zero for a whole run on early scores: candidate quality is high-variance by design, and a channel that loses four iterations and then finds the winner is the reason three are running. Fold it to one candidate per iteration; do not remove it.

---

## L5. Termination

- **Target hit** → stop, run the held-out oracle, report both numbers (§L3), hand the winning diff to Phase 3 acceptance.
- **Budget exhausted** → stop, report best-so-far with its held-out reading and the honest remaining gap to target. "Ran out of budget at 0.71 against a target of 0.80" is a result; "improved to 0.71" is that same result with the part the user needed removed.
- **Stall** → K consecutive iterations whose best score did not improve by more than `spread` (§L2). K = 2 at S/M, 3 at L. Stop and escalate; a fourth iteration inside the noise band is buying nothing. Before the user gate, spend one maximum-depth pass over the whole attempt history (SKILL.md "when stuck") — that is where the loop's own record earns its keep, since every failed candidate and its death stage is on disk.
- **Held-out regression while the proxy improves** → stop immediately, user gate (§L3). This one does not wait for the budget or the stall counter.
- **Frozen-set violation** → stop immediately, user gate (§L2).
- **Hard ceilings**, so a runaway is bounded regardless: iterations ≤ 12, oracle runs ≤ the charter's `budget.oracle_runs`. Re-confirm with the user before crossing either, with the actual spend so far against the estimate given at the crew proposal — the same rule and the same wording as `patterns.md`'s round-5 floor, for the same reason: the party that pays for stopping should not be the only one holding the brake.

**The winner still goes through Phase 3.** A candidate that satisfies the oracle has been measured, not reviewed — nothing in the cascade looks at security, edge cases, or spec compliance, and an optimizer is exactly the process most likely to produce code that is correct on the measured path and nowhere else. Run the acceptance gate at the task's scale on the winning diff, and read a finding there as a finding about the loop's objective function, not only about the patch.

---

## L6. State and packets

`state.json` gains a `loop` block on any `loop`-routed task, at every scale (unlike the multi-round machinery, which is L-only — a loop is multi-iteration by definition, so the bookkeeping is never dead weight here):

```json
"loop":{"charter":".babel/<task>/loop.md","iteration":3,
 "baseline":{"score":0.62,"spread":0.01,"runs":[0.62,0.61],"at":"3f9c2ab"},
 "best":{"score":0.81,"iteration":2,"channel":"sol","patch":"iters/i2-sol.diff","base":"3f9c2ab"},
 "held_out":{"baseline":0.60,"final":null},
 "frozen":"frozen.manifest","stall":1,
 "candidates":[{"iteration":3,"channel":"agy","patch":"iters/i3-agy.diff","died":"cascade-3","score":null}],
 "budget":{"iterations_max":12,"oracle_runs":11}}
```

`candidates[]` keeps every attempt with the stage it died at — that history is the input to the stall escalation and the only record of what the loop already ruled out. `held_out.final` stays `null` until promotion; a report written while it is `null` has no right to a success claim.

**`LoopContext`** (lead → generator channels, one per iteration):
```
{charter:str, base:str, best:{patch,score}|null, last_scores:[{channel,score|null,died?}], rejected:[str], out_schema:"unified-diff"}
e.g.: {"charter":".babel/t/loop.md","base":"3f9c2ab","best":{"patch":"iters/i2-sol.diff","score":0.81},"last_scores":[{"channel":"claude","score":0.74},{"channel":"agy","score":null,"died":"cascade-1"}],"rejected":["9f3a1c04"],"out_schema":"unified-diff"}
```
`out_schema` is `unified-diff` and the response is the diff and nothing else — no prose, same discipline as `protocol.md` §4. agy receives the base hunks inline per §1; SOL and Claude read the worktree.

**`CandidateRecord`** is the lead's own row in `candidates[]` above; channels never write it.

Secret scanning (`protocol.md` §0) covers the `LoopContext` like any other external-bound payload — and note that a loop sends one *per iteration*, so a payload scanned once at iteration 1 has been re-sent a dozen times by the end.

---

## L7. Degradation

The loop degrades along the same axis as everything else: fewer channels, not a different procedure.

- **One external dead** → two generators. Unchanged otherwise; the oracle still selects.
- **Both externals dead (single-channel minimal mode)** → the loop still runs, with candidates generated by distinct in-Claude viewpoints (a Sonnet worker per iteration, prompted along different lines of attack — data structure / algorithm / constant factor, as the task admits). Say "reduced diversity (no external models)" in the report. **This is the degradation that costs the most**, and it should be stated rather than glossed: the loop's whole selection pressure is diversity of candidates, and three prompts to one model are correlated in a way three models are not.
- **No `Workflow` tool** → generate candidates as parallel Agents and isolate with `git worktree add` directly. Nothing in §L4 depends on `Workflow`.
- **Oracle turns flaky mid-run** (a re-run of a scored candidate disagrees with its recorded score by more than `spread`) → stop. Every score before that point is suspect and the loop has no way to tell how far back it started. Report it as a void run, the same reading `protocol.md` §4 gives a void round: not a failure to improve, an inability to say whether anything improved.

---

## L8. Prior art

The mechanisms above are adapted from public work rather than invented here; where a rule looks arbitrary, this is the reason it has that shape.

- **AlphaEvolve** (DeepMind) and its open implementation **OpenEvolve** — the evaluation cascade (§L2), the prompt sampler that carries past programs *with their scores* into the next generation (§L4 step 1), and the island/population model babel maps onto its channels. https://github.com/codelion/openevolve
- **ShinkaEvolve** — sample efficiency under a small budget: novelty-based rejection filtering (§L4 step 4) and a bandit over an LLM ensemble, which babel already had in `advanced.md` §A9 and now feeds with objective rather than adjudicated outcomes. https://github.com/SakanaAI/ShinkaEvolve
- **EvilGenie**, **SpecBench**, **RewardHackingAgents** — the empirical case for §L3. They separate a proxy metric from a true objective measured on held-out tests, name evaluator tampering and held-out leakage as the two vectors, and detect the first by watching for test-file edits. The finding that motivated making the frozen set mechanical rather than instructional is that current frontier coding agents — Claude Code among them — do reward-hack these setups when the option is available.

babel's contribution over these is not the loop; it is that the loop's generators are three *different vendors' models* and its selector is an oracle rather than a vote, which is the one configuration where an ensemble is strictly cheaper than adjudication.

---

## L9. Fan-out — proposing a Dynamic Workflow

Not a babel route so much as a **recommendation babel is obliged to make** when it sees the shape, because the shape is one babel's own phases handle badly: N mostly-independent sites, each needing the same small judgment, where the lead's context is the bottleneck and there is nothing to debate.

**Propose `fanout` when all three hold:**
1. The work-list is **enumerable** — now, or after one scout pass the lead runs itself (grep the call sites, list the packages, read the failing suite). Do not propose a fan-out over a list nobody has produced; the scout pass is cheap and a fan-out over a guessed list is N agents doing the wrong N things.
2. Items are **independent** — no two items write the same file, or worktree isolation covers the overlap.
3. **N ≥ 5.** Below that the orchestration overhead exceeds the parallelism, and the lead should just do it.

Classic shapes: a mechanical migration across call sites, an audit sweep over many modules, per-package test repair, a broad multi-angle search where each agent searches a different way.

**The proposal is the deliverable, not the launch.** The `Workflow` tool requires the user to opt into multi-agent orchestration in their own words, and babel's own crew approval is not that opt-in — a skill that reads its earlier approval as consent to spawn dozens of agents has laundered a gate the tool put there deliberately. So: describe it, price it, and wait. State the enumerated work-list and its size, the per-item cost and the total order of magnitude, whether worktree isolation is needed, and the shape (`pipeline()` by default — a barrier is only correct when a stage genuinely needs every prior result at once, e.g. dedup across the full set). Then let the user say yes.

If they decline, run `linear` and say what it will cost instead. If they accept, the fan-out replaces Phase 2 and the results still go through Phase 3 at the task's scale — N mechanical edits are exactly the changeset an acceptance gate is for.

**Routes compose, and the useful composition is loop-inside-fanout's opposite:** a `loop`-routed task whose candidate generation is itself wide (many candidates per iteration rather than one per channel) is a fan-out *inside* §L4 step 2, and it needs the same user opt-in before it fires. A loop is not a licence to widen.
