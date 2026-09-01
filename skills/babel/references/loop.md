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
3. **Affordable.** `oracle_seconds × (channels + 1) × expected_iterations` fits the budget stated at the crew proposal — one full run per surviving candidate, plus the leader's confirmation run (§L4 step 6). The `+1` is the part that gets forgotten, and the per-channel multiplier is the part that gets halved: the cascade runs on every candidate from every channel, not once per iteration.
4. **Search, not specification.** The reason this is not already done is that nobody knows *which* change wins — not that nobody has said *what* is wanted.

**Predicate 4 is the one that actually gets skipped, and skipping it is the expensive error.** A task where 1-3 hold and 4 fails is an ordinary `linear` task that happens to own a good test suite. Looping on it buys nothing: iteration 1 produces the change the lead would have written anyway, and iterations 2..N pay full oracle cost to confirm it. Say "this has an oracle but no search — running it linear" in the crew proposal and route `linear`. The symptom to watch for is a user who can already describe the fix; if they can, there is nothing to search.

If 4 holds but 1 or 2 fails, **do not fabricate an oracle to unlock the route.** A metric invented by the lead to make a loop runnable is a metric nobody has agreed measures the goal, and the loop will optimize it perfectly. Either build the oracle as a `linear` task first and re-route afterwards (say so, and get that split approved), or run `linear`.

---

## L1. The loop charter — eliciting the goal before spending anything

A loop with an underspecified goal does not fail; it succeeds at the wrong thing for its entire budget. So the charter is a **user gate** — the fifth, alongside the four in `protocol.md` §0 — and it fires at iteration 0 — before the baseline is measured and before anything is spent — at every scale, on every `loop`-routed task.

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

And three the lead may draft and have confirmed rather than asked cold: `budget` (max iterations, max oracle runs, token ceiling), `held_out` (§L3), `frozen` (§L2 — defaults to the oracle, its inputs, every test file, **and the build/lint configuration cascade stage 3 executes** — `Makefile`, `package.json`, `pyproject.toml`, `setup.cfg`, `tox.ini`, `.pre-commit-config.yaml`, lint configs; a candidate that edits the build script has put its own code in front of the shell — which is usually right and must still be shown. Files are valid frozen roots, not only directories).

`metric` and `target` together are the loop's whole objective function. If the user cannot state a target, that is not a charter to complete with a placeholder — it is evidence that predicate 4 failed and the task wants a `linear` route with a review, which is worth saying rather than looping.

---

## L2. The oracle contract

**Iteration numbering, fixed here and used everywhere in this file.** **Iteration 0 is setup and produces no candidate**: the charter is approved (§L1), the frozen manifest is recorded, and both the proxy and held-out oracles read their baselines. **Iterations 1..N are candidate rounds.** Everything counted — the stall counter, the re-approval trigger at iteration 5, the ceiling of 12 — counts candidate rounds, so iteration 0 is never one of them. A file that says "before iteration 0" and "before iteration 1" for the same moment leaves the lead to guess whether setup was free, and it is not.

### Baseline, and noise

**Run the oracle twice on the untouched tree, at iteration 0.** Record both readings. `spread` = the difference.

This is not ceremony. Every subsequent "improvement" is a comparison against the baseline, and an improvement smaller than `spread` is not an improvement — it is the same measurement taken twice. Without a recorded spread, the loop's stall detector cannot fire (the score keeps "moving"), the winner selection promotes noise, and the final report claims a gain the user cannot reproduce. A loop that skipped this reports a number it has no right to.

For a pass/fail oracle the spread is 0 by construction and the two runs instead prove determinism: two different verdicts on the same tree means the oracle is flaky, and a flaky oracle is not an oracle. Fix or replace it before iterating — a flaky verdict makes candidate selection a coin flip that costs a full iteration to toss.

### Cascade — cheap gates first

Most candidates are wrong, and the full oracle is the expensive way to learn it. Score every candidate through stages of rising cost, stopping at the first failure (the evaluation cascade from AlphaEvolve/OpenEvolve, §L8):

1. **Applies.** `git apply --check` against the iteration's base. A patch that does not apply costs nothing to reject and is the most common failure of a channel that reasoned about a stale tree.
2. **Frozen set intact.** The gate below. This one is a *hard stop*, not a low score — see §L3.
3. **Builds / typechecks / lints.** The repo's own fast checks, whatever a contributor runs locally. These run code from the candidate tree on a host with no sandbox, which is why the build/lint configuration they read is in the default frozen set (§L1): stage 2 has already established that nothing the commands read was rewritten.
4. **Fast subset of the oracle**, where one exists (a smoke case, one benchmark shape, the first N tests). Reject anything that regresses here.
5. **Full oracle.** Only survivors reach it.

Record which stage each candidate died at. That distribution is diagnostic on its own: everything dying at stage 1 means the context packet is stale, everything at stage 3 means the channels are not being told how the project builds.

**What `budget.oracle_runs` counts, so the ceiling means something**: every execution of the **full** oracle (stage 5), every **confirmation** run (§L4 step 6), and the two **held-out** runs. Stages 1-4 are not counted — they are the cheap gates whose whole purpose is to be run freely — but stage 4's per-run seconds still go into the §L0 predicate-3 estimate, because "not counted" and "not paid for" are different things. Budget it at roughly `channels + 1` full runs per iteration: one per surviving candidate, plus the leader's confirmation run.

### The frozen set — enforced mechanically, never by prompting

The oracle, its inputs, and the tests are the only reason any score means anything. A candidate that edits them has not improved the code; it has moved the finish line. Telling the channels not to do that is not a control — a control is a check that runs whether or not anyone complied.

Record the manifest at iteration 0 (numbering above), **outside** any tree a candidate is applied in — a manifest stored where the candidate can reach it is a record of the oracle that the candidate can edit to match:

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
  # Symlinks too, not only regular files. `git apply` creates mode-120000 entries
  # and pytest loads a conftest.py through one; a `-type f` listing never saw it,
  # so a symlinked addition passed the gate with the manifest unchanged.
  # Every .gitignore in the tree as well, wherever it lives: the ignore filter
  # below reads them, and a candidate that edits the root .gitignore to cover its
  # addition has touched nothing under a frozen root — the addition then drops out
  # as a "build artifact". Both measured against this block, both caught now.
  { for r in "$@"; do
      find "$t/$r" \( -type f -o -type l \) -print
    done
    find "$t" -name .gitignore -not -path "$t/.git/*" -print
  } | LC_ALL=C sort -u > "$FROZEN.list"
  # Drop anything git ignores. Measured on the first real run of this route:
  # without it the gate fires on the __pycache__/*.pyc the oracle's own
  # execution wrote beside itself, and reports it as a candidate tampering
  # with the evaluator. A control that cries wolf on its own build artifacts
  # is a control that gets switched off. An empty pattern file matches
  # nothing, so with no ignores every line survives — which is also what
  # happens outside a repo, in the selftest's throwaway tree.
  # Only when $t is the TOP LEVEL of a worktree. A plain subdirectory of some
  # other repository answers this question about that repository — and since
  # `.babel/` is itself gitignored, a tree living under it would come back
  # "entirely ignored" and the manifest would be empty, which frozen_record
  # below rejects as an unenforceable oracle. Found exactly that way.
  : > "$FROZEN.ign"
  top=$(git -C "$t" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$top" ] && [ "$top" = "$(cd "$t" && pwd -P)" ]; then
    git -C "$t" ls-files --others --ignored --exclude-standard \
      | sed "s|^|$t/|" > "$FROZEN.ign"
  fi
  grep -vxF -f "$FROZEN.ign" "$FROZEN.list" | while IFS= read -r f; do
    # A symlink is recorded by its target string, never by the target's content:
    # hash-object follows the link, so a link swapped to point elsewhere would
    # hash as "unchanged" whenever the new target has the old bytes.
    if [ -L "$f" ]; then printf 'link:%s  %s\n' "$(readlink -- "$f")" "${f#"$t"/}"
    else printf '%s  %s\n' "$(git hash-object -- "$f")" "${f#"$t"/}"; fi
  done
}

frozen_precheck() {   # iteration 0, BEFORE frozen_record — a setup gate, not a violation gate
  t=$1; shift
  u=$(git -C "$t" ls-files --others --exclude-standard -- "$@" 2>/dev/null) || return 0
  [ -z "$u" ] || {
    printf 'frozen roots contain files git does not track:\n%s\n' "$u" >&2
    echo 'commit them or gitignore them before iteration 0 — see below' >&2
    return 2
  }
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

**The frozen set must be committed before iteration 0, and `frozen_precheck` is what enforces it.** §L4 step 3 isolates every candidate in its own git worktree, and a worktree built from a commit does not contain uncommitted files — so an oracle sitting untracked in the working tree simply *is not there* when the candidate is scored, and `frozen_check` reports its absence as a modified frozen set. Measured on the first run of this route: the gate fired on iteration 1 and the cause was an uncommitted oracle, not a candidate. That reading is worse than useless, because it spends a user gate on a setup mistake and teaches the lead that the gate is noisy. Run `frozen_precheck` first; it fails with **2 (setup)**, which is a different exit status from `frozen_check`'s **1 (violation)** precisely so the two never get confused.

**A `frozen_check` failure is a user gate, not a score of zero.** Rejecting the candidate quietly and iterating on is the wrong response: the loop has just observed a channel optimizing the evaluator instead of the code, and that fact is worth more to the user than the candidate was. Stop, report which paths moved and which channel proposed it, and let the user decide whether to continue with that channel dropped.

**The lead runs the oracle, from the lead's own copy of the command.** Never a command a candidate wrote, edited, or "suggested a tweak to" — that is executing external output, which `protocol.md` §0 forbids and §7 already spells out for repro commands. The oracle command is fixed at charter time and re-read from `loop.md`, not from anything an iteration produced.

---

## L3. Proxy versus true objective

The oracle is a **proxy**. It is the thing being optimized, and anything being optimized by a capable model will eventually be optimized *as stated* rather than as intended. Benchmarks of exactly this failure on coding agents name two vectors — tampering with the evaluator, and reading the held-out data — and find current frontier coding agents doing both (§L8). babel's answer is one structural rule per vector:

- **Evaluator tampering** → the frozen set (§L2), checked mechanically before every score.
- **Leakage into the metric** → a **held-out oracle**, which the loop never runs per-iteration and which no context packet ever mentions. Charter field `held_out`: a second command (a different test file, a different input set, a later slice of data) that measures the same intent. It runs exactly twice — once at baseline, once on the promoted winner.

**A different slice of the same metric is not a held-out.** The test, applied at charter time before anything is spent: *could a change that merely moves content around move both numbers the same way?* If yes, the second command is the proxy wearing a different mask, and the whole of this section is decoration. Measured on the first run of this route: the drafted held-out was the same byte-count oracle over a wider reading set, the winning candidate moved both by relocating text, and the "held-out improved too" row below read as success for a change that had actually made rules unreachable at another scale. A real held-out measures the *intent* by a different mechanism, not the same mechanism at a different scope.

**When the user's invariant is not measurable, say so instead of proxying it.** The invariant that matters is often something no command scores — "the output does not get less accurate", "it stays readable", "the team can still follow it". Then the honest configuration is a **guard**, not a metric: a check that bounds *what was destroyed* (rules deleted, references broken, tests failing) and says nothing about whether quality held. Report it in exactly those words. Promoting a guard to a held-out — "the guard is green, so accuracy held" — is the same fabrication §L0 forbids when it says not to invent an oracle to unlock the route, committed one step later in the run.

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

1. **Build the context packet** (`LoopContext`, §L6). At iteration 1 it is one packet, identical for every channel: the charter, the current base tree pointer, the best-so-far patch **with its score**, the scores per channel, and the rejected-fingerprint list. From iteration 2 it is **one packet per channel**, sliced by that channel's cursor (next paragraph) — the *content* stays common knowledge, only the already-delivered part is dropped, so no channel is given anything a sibling was not. Carrying the best patch and its number forward is what makes three channels compound instead of running three independent single-model loops — it is the prompt-sampler idea from AlphaEvolve (§L8), and it is the difference between an ensemble and three people guessing in separate rooms.

   **From iteration 2 on, every channel gets a delta, not the packet again** — the same rule `advanced.md` §A1 already applies to stateless reviewers, and a loop is where it matters most: the generators are re-dispatched a dozen times, so re-sending the charter and the whole history each time pays for the same bytes twelve times over. Keep a per-channel cursor in `loop.cursors` (§L6) and send only what moved since that channel's `last_seen`: the winning diffs it has not seen, the score rows added since, and the fingerprints added since. The charter is sent **once**, at iteration 1 — it is fixed for the run by definition, and a channel that needs it re-stated has not been reading it.

   Two rules carry over from §A1 unchanged, and both are load-bearing here. Capture the snapshot **at dispatch** and commit it together with `last_seen` only once that channel's response clears the schema gate: a generator that times out or returns prose must not have its cursor advanced, or the next delta compares against a base it never saw and silently omits the winner it was supposed to build on. And a laggard channel — one that missed iterations — gets the union of the deltas it missed, not the latest one alone.

   Measured expectation, stated so it can be checked rather than assumed: iteration 1 is the expensive one (charter + base acquisition), and iterations 2..N should be a fraction of it per channel. **If they are not, the delta is not being built** — that is the symptom to look for in the per-iteration spend, and it is the single largest token lever in this file.
2. **Generate blind and in parallel.** Claude (a Sonnet worker, or the lead at S), SOL, and agy each propose **one candidate diff** against the same base, without seeing the siblings' candidates for that iteration. Same anchoring rule as `#debate-aggregation` and the same-round blindness of `protocol.md` §8 — and here it is load-bearing rather than hygienic: three candidates that saw each other are one candidate with three sets of edits, which is the failure the whole route is built to avoid.

   **The blindness boundary is the iteration, and it binds the fold ladder's direction hints too.** Anything a sibling produced during iteration N — a candidate, a score, a direction-only hint — enters the others' packets at iteration N+1, never during N. A hint collected and injected inside the same iteration is exactly the leak the blindness rule exists to stop, and it is the easy one to introduce because a direction hint is cheap and arrives early.

   **SOL runs at `--tier normal`. Never `deep` for loop generation**: the deep cap is 2 per task (`advanced.md` §A7) and a loop would consume it by iteration 3, spending on routine candidate generation the budget that exists for the one hard diagnosis. Deep belongs to the stuck playbook — if the loop stalls (§L5) and §A2 fires, that is where the task's deep calls are spent, once.
3. **Isolate.** Candidates touch the same paths by construction, so apply each in its own worktree (`Workflow`'s `isolation: 'worktree'`, or `git worktree add` directly). This is the one place in babel where worktree isolation is not a luxury.
4. **Reject on novelty before spending.** A candidate whose normalized diff fingerprint matches one already in `rejected[]` is dropped at zero oracle cost — the novelty-rejection idea from ShinkaEvolve (§L8), implemented on the fingerprint list `protocol.md` §5 already keeps. Normalize by stripping whitespace and comment-only lines before hashing; a re-proposal with a reworded comment is the same candidate.
5. **Score through the cascade** (§L2). Ties inside `spread` are not ties to break on preference — prefer the **smaller diff**, stated as the rule rather than decided per case, because the alternative is the lead picking its own channel's candidate on a coin flip.
6. **Confirm before promoting, and do not promote inside the noise band.** Two rules, and skipping either is how a loop reports a gain it cannot reproduce:
   - The leading candidate must beat the **current base** by more than `spread` (§L2). A candidate that does not is not a small win, it is an unmeasurable one: promoting it makes the base a random walk, and every later "improvement" is then measured against a base that drifted for free. The base stays and the iteration counts toward the stall counter.
   - Then **re-run the full oracle on that one candidate** — the confirmation run. **Skip it when `spread` is 0 and the iteration-0 pair proved the oracle deterministic** (§L2): re-running a deterministic command returns the same number by construction, so the run buys no information and the rule would be pure cost every iteration. Measured on the first run of this route, whose oracle was a byte count. Everywhere else it is mandatory. Promote only if the second reading also clears the base by more than `spread`. This costs one extra full-oracle run per iteration, on the leader only and never on the losers, and it is what supplies the re-run §L7's flaky-oracle rule already assumes exists: if the two readings of the *same* candidate disagree by more than `spread`, that is not a marginal candidate, it is a flaky oracle, and §L7 applies to the whole run.
   Why both, given the baseline already ran twice: `spread` taken from two runs is the range of a two-sample draw, which under-estimates true variance rather than bounding it. Treat it as a **lower bound on noise, not a confidence interval** — the confirmation run is what compensates, and it is deliberately cheap because it is one run on one candidate.
7. **Promote and migrate.** The winner becomes the next iteration's base and its patch + score go into every channel's next context packet. Record the loser patches; they are the diversity the next iteration is drawing from, and deleting them is how a loop collapses onto one line of attack.
8. **Score the channels, with the objective label.** Append the iteration to `channel_scoreboard` exactly as an acceptance round would (`protocol.md` §5), with a grounding record per candidate carrying **`method:"oracle"`** — `check` = the oracle command the lead ran, `result` = the measured delta against the base, `at` = the candidate patch path. This is a strict instance of §7's "the verifier executes, not opines", not a loosening of it: an oracle run is an executed command with a recorded result, which is what `repro` already means. It is *stronger* evidence than an acceptance round produces, because the verdict is a number nobody argued for.

That last point makes the existing bandit (`advanced.md` §A9) work here unchanged and better: a channel whose candidates never survive the cascade is folded on measured reward rather than on the lead's impression of it. Fire it under the same condition — **multi-iteration only**, ≥3 iterations expected; below that it is noise.

**What "fold" means here has to be defined, or the rule cannot act.** §A9's fold is "reduce the channel to its cheapest useful form", and for a reviewer that is one dimension group — but a loop generator already produces exactly one candidate, so "fold to one candidate" is the state it is in and the bandit would measure without ever being able to spend less. The ladder, in order:

1. **full candidate every iteration** (the starting form);
2. **candidate every other iteration** — half the spend, and the channel still contributes diversity on the iterations it runs;
3. **direction-only** — no diff at all: at most two lines naming a line of attack it thinks nobody is trying, carried into the other channels' next packet as a hint. This is roughly two orders of magnitude cheaper than generating a patch and is the form to fold to before considering removal.

Do **not** drop a channel to zero for a whole run on early scores: candidate quality is high-variance by design, and a channel that loses four iterations and then finds the winner is the reason three are running. Step down the ladder one rung per fold decision; direction-only is the floor.

---

## L5. Termination

- **Target hit** → stop, run the held-out oracle, report both numbers (§L3), hand the winning diff to Phase 3 acceptance.
- **Budget exhausted** → stop, report best-so-far with its held-out reading and the honest remaining gap to target. "Ran out of budget at 0.71 against a target of 0.80" is a result; "improved to 0.71" is that same result with the part the user needed removed.
- **Stall** → K consecutive iterations whose best score did not improve by more than `spread` (§L2). K = 2 at S/M, 3 at L. Stop and escalate; a fourth iteration inside the noise band is buying nothing. Before the user gate, spend one maximum-depth pass over the whole attempt history (SKILL.md "when stuck") — that is where the loop's own record earns its keep, since every failed candidate and its death stage is on disk.
- **Held-out regression while the proxy improves** → stop immediately, user gate (§L3). This one does not wait for the budget or the stall counter.
- **Frozen-set violation** → stop immediately, user gate (§L2).
- **Mid-run re-approval, not only at the ceiling.** Ask the user before dispatching **iteration 5** (i.e. once 4 iterations are done), and again whenever cumulative spend passes **2× the estimate** given at the crew proposal — whichever comes first, each firing once. This mirrors `patterns.md`'s `rounds_consumed`=4 trigger and its round-5 floor, and it is here for the identical reason spelled out there: stopping costs the lead something, so a design where the only brake is at the ceiling leaves it in the hands of the party that pays for pulling it. A ceiling-only gate is what the loop had before this rule, and 12 iterations at three channels is a millions-of-tokens run reaching the user for a second time only after it is over.
  **The spend trigger degrades to the iteration trigger, and that has to be said rather than assumed.** Cumulative spend is the sum of non-null `tokens` across the loop's `channel_scoreboard` entries (`protocol.md` §5), and §5 forbids guessing at a channel whose spend the harness does not report. If every channel reports `null`, the 2× trigger can never fire and **iteration 5 is the only brake** — say so at the crew proposal rather than quoting a spend ceiling that cannot be evaluated.
- **Hard ceilings**, so a runaway is bounded regardless: iterations ≤ 12, oracle runs ≤ the charter's `budget.oracle_runs`. Re-confirm before crossing either, with the actual spend so far against the estimate.

**Reachability is the regression a numeric oracle cannot see.** Content that is *moved* — out of a read set, behind a scale gate, into an appendix — is not deleted, so a rule-inventory guard reports nothing lost, and the byte count improves precisely because a reader no longer reaches it. Measured: the first run of this route produced a winner that cut the proxy 9.4% by splitting a section, and made the moved half unreachable at a scale that needs it, with every automated check green. Whenever a candidate moves rather than rewrites, the lead reads the routing that governs who sees the moved half — the reading maps, the scale gates, the cross-references — by hand, and treats a gap there as a defect in the candidate, not as a finding for later.

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
 "cursors":{"sol":{"last_seen":2,"snapshot":{"src/hot.py":"a91f:2048"},"form":"full"},
            "agy":{"last_seen":1,"snapshot":{},"form":"alternate"},
            "claude":{"last_seen":2,"snapshot":{"src/hot.py":"a91f:2048"},"form":"full"}},
 "candidates":[{"iteration":3,"channel":"agy","patch":"iters/i3-agy.diff","died":"cascade-3","score":null}],
 "budget":{"iterations_max":12,"oracle_runs":11,"estimate_tokens":900000,"reapproved_at":[]}}
```

`candidates[]` keeps every attempt with the stage it died at — that history is the input to the stall escalation and the only record of what the loop already ruled out. `held_out.final` stays `null` until promotion; a report written while it is `null` has no right to a success claim.

`cursors` is the token control, and it is present at **every** scale here for the reason the review-side `cursors` is L-only: a loop re-dispatches its generators by definition, so there is never an iteration count low enough for the delta to be dead weight. `last_seen`/`snapshot` carry exactly the §A1 meaning and follow the §A1 commit rule (captured at dispatch, committed with `last_seen` only after the response clears the gate). `form` is the fold ladder rung from §L4 — `full` | `alternate` | `direction` — so a fold decision is a state change with a name rather than a wider prompt the lead remembers to write. `budget.estimate_tokens` is what was quoted at the crew proposal, which is the denominator the 2× re-approval trigger (§L5) reads; `reapproved_at` records the iterations the user was actually asked at, so a resumed run does not re-ask or, worse, skip.

**`LoopContext`** (lead → generator channels). **Iteration 1 sends the full packet; iteration ≥2 sends the delta form** — same fields, `charter` omitted and the three list fields carrying only what postdates that channel's `last_seen`:
```
{charter?:str, base:str, best:{patch,score}|null, new_wins:[{iteration,patch,score}], new_scores:[{iteration,channel,score|null,died?}], new_rejected:[str], form:"full"|"direction", out_schema:"unified-diff"}
e.g. iter 1: {"charter":".babel/t/loop.md","base":"3f9c2ab","best":null,"new_wins":[],"new_scores":[],"new_rejected":[],"form":"full","out_schema":"unified-diff"}
e.g. iter 3: {"base":"7c2e001","best":{"patch":"iters/i2-sol.diff","score":0.81},"new_wins":[{"iteration":2,"patch":"iters/i2-sol.diff","score":0.81}],"new_scores":[{"iteration":2,"channel":"agy","score":null,"died":"cascade-1"}],"new_rejected":["9f3a1c04"],"form":"full","out_schema":"unified-diff"}
```
`new_rejected` is **only the fingerprints added since that channel's `last_seen`**, never the whole list — the list grows monotonically and is sent to three channels every iteration, so re-sending it whole is a quadratic cost for a linear amount of information. A channel that missed iterations gets the union of what it missed (§L4 step 1, laggard rule), which is what makes per-channel slicing correct rather than merely cheaper.

`out_schema` is `unified-diff` and the response is the diff and nothing else — no prose, same discipline as `protocol.md` §4. `form:"direction"` is the one exception, and it is not a diff at all: at most two lines naming a line of attack (§L4 fold ladder). agy receives the base hunks inline per §1; SOL and Claude read the worktree, so for them `base` costs a git ref rather than a payload — which is why agy is the channel the delta saves the most on and also the one the 32 KB cap binds first.

**`CandidateRecord`** is the lead's own row in `candidates[]` above; channels never write it.

### Resuming a loop

A loop is the longest-running thing babel does, so it is the most likely to be picked up in a new session — and the state above is enough to resume only if three things are re-established first, in this order:

1. **Re-run `frozen_check` against the pristine tree** (§L2). The manifest describes a tree that may have moved while nobody was looking; resuming on a frozen set that has changed since it was recorded scores every remaining iteration against a different evaluator than the earlier ones. A mismatch here is not a candidate violation — nobody was iterating — but it does void the earlier scores, and that is a user gate, not a silent re-baseline.
2. **Re-read the baseline, once, and compare to `loop.baseline`.** Machine, load and toolchain all differ across sessions. A reading outside `spread` means the recorded scores are not comparable with anything measured from here on: re-baseline and say that the earlier iterations' numbers are being retired, rather than continuing a series that changed units mid-way.
3. **Discard every candidate worktree** and rebuild from `loop.best.base`. A worktree left by a killed session is an unknown tree, and the cheapest correct assumption is that it is not the one its name claims.

`reapproved_at` then decides the gates: an iteration already listed there is not re-asked, and one that is due and missing is asked before the first dispatch of the resumed run. `candidates[]` carries over untouched — it is the record of what was already ruled out, and re-deriving it would re-spend the whole run.

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

**Routes compose, in one direction: fan-out inside a loop, never a loop inside a fan-out.** A `loop`-routed task whose candidate generation is wide — many candidates per iteration rather than one per channel — is a fan-out sitting inside §L4 step 2, and it needs the `Workflow` opt-in above before it fires. A loop is not a licence to widen. The reverse does not compose at all: a loop *inside* each fan-out item multiplies an unbounded iteration count by N items, with no single place holding the budget.
