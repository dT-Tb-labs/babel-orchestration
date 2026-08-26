# Project Memory
最終更新: 2026-08-26

## 現在の状態

master pushed, tree clean (`git log --oneline -1` for where — a hash written here is stale by the
next commit, including the one that writes it). This session added CI and made `memory.md` tracked;
`skills/babel/memory.md` was an unreferenced 4-line stub, deleted.

**Verification: `sh skills/babel/tests/run-all.sh` — 6 passed, 0 failed, 0 not run** (outside the
sandbox, and on every CI run). Two execution paths now: install.sh (lenient) and CI (`--strict`).

**Never run `gate-selftest.sh` or `loop-selftest.sh` inside the sandbox.** They create a scratch dir
at the repo root and their `trap ... EXIT` cannot delete it there, so it survives and every later run
refuses to start — and `pre-bash-policy-guard.js` blocks `rm -rf` outside scratch space **even after
the user confirms in chat**, so only the user can clear it. `loop-selftest` additionally fails there
with a misleading assertion whose real cause is `git init` being denied its hook templates.
`run-all.sh` reports both classes as BLOCKED, not FAIL. Run outside the sandbox, or from a clone.

**Measured gotchas (kept, each paid for):**
- **Never `git checkout -- <file>` to undo a mutation while that file holds uncommitted work.** It reverted a whole finished section; three "RED (good)" results that run were the destruction, not the mutation. Copy the file aside and restore from the copy.
- Wrapping `agyask` in a `for` loop stops it matching `sandbox.excludedCommands`, so agy runs inside the sandbox and dies (`bind: operation not permitted`). Dispatch each call as its own bare command.
- Under `set -e`, `_x=$(cmd)` with non-zero `cmd` kills the script.
- `printf '--foo'` — bash printf parses the leading `--` as an option. Reword or use `printf '%s\n'`.
- Cross-provider token fold unavailable: agy and codex total unlike quantities. A9 folds within a provider only.
- **Cost**: the M acceptance gate on A9/A10 cost SOL 2.03M tokens against a 150-350k quote. Quote SOL acceptance an order of magnitude higher.

## 直近の作業

**CI** (`.github/workflows/tests.yml`, merges `9950947` / `9a84150`) — push / pull_request runs
`run-all.sh --strict` on ubuntu-latest; node and python3 are preinstalled, so no setup steps.
`--strict` exits 1 if any test did not run (a runner has no sandbox and no leftover scratch dir, so
BLOCKED there is a signal). install.sh deliberately stays lenient. A second step checks `--strict`
itself: hide node so a6-selftest SKIPs, then assert `--strict` exits 1 **and** a plain run exits 0 —
asserting only the failure would still pass if run-all.sh broke for another reason. Runtime 6-9s.

**A9 pairwise co-failure + A10 MAST labels** (merge `d192f28`) — read them in advanced.md §A9/§A10
and protocol.md §5, not from here. Passed the M gate over 2 rounds; round 2 found 3 H defects,
**every one in a line round 1's fix had just written**. The durable lesson: round 1 took an external
finding's *conclusion* at face value instead of re-deriving which half of the rule it broke.
Round 3 was deliberately not run — M's re-review fires once, the rest is residual risk to the user.

**A6 harness** (`tests/a6-selftest.mjs`, `00d0d9c`) — 30+ assertions, 6 mutations RED, A6 itself
defect-free. Its commit message claims A6 was untested; that is **wrong** and stays uncorrected
(pushed) — install.sh already parsed the block and checked the receipt gate over 7 cases. Untested
were the args guard, void round, bracket, verify routing, rejection, and cap accounting.

## 次のタスク / 未解決

- **A9/A10 は M ゲート通過済みだが、ラウンド2の修正は未測定で運用実績 N=0。**
- **A10 の天井（明記済み、未解決）**: repo スコープの記録は段4（`~/.claude/`）に構造上到達しない / Claude が Claude を律するルールを裁く循環はオフライン化で薄まるだけ / `rule.quote` と `prescribed` は帰属対象自身の自己申告 / テストAは存在証明であって注入証明ではない。
- **context cost（前回の誤読を訂正済み）**: `context-cost.py` はバイトを出す（~4 bytes/token）。s-linear 58,123B ≈ 14.5k tokens / m-linear ≈ 24k / l-loop ≈ 43k。**「S は修正より規則のほうが大きい」は誤り** — 圧縮の優先度は低い。
- 旧来の未解決: A9 の reward に coverage 項が無い / severity が集約されない / CRB 外部ベンチ未実施 / source delay が (a) トラックを端から端まで覆っていない。詳細 `.babel/HANDOFF-next.md`（gitignored）。
- 未検証: A6 の reviewer/verifier 死亡、Windows 分岐、Fable5 チャネル。
- memory.md は public repo で追跡対象。コスト実績も未解決欠陥もそのまま公開される。
