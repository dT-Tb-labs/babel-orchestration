# Project Memory
最終更新: 2026-08-26

## 現在の状態

master `c9b2cee`, pushed, origin/master in sync. Merged `feat/co-failure-and-mast-labels`
This session: `49d60bd` feat + `67dae92`/`e115636` acceptance fixes, merged `--no-ff` as `d192f28`,
then `00d0d9c` (A6 harness) and `c9b2cee` (run-all.sh + install.sh wiring). Branch deleted. Tree clean.

**Verification: `sh skills/babel/tests/run-all.sh` (outside the sandbox) — 6 passed, 0 failed, 0 not run.**
Individually: `gate-selftest.sh` / `loop-selftest.sh` /
`rule-attribution-check.sh` / `deadline-check.sh` / `install.sh` PASS, `rule-inventory.py` broken 0.
**Never run `gate-selftest.sh` or `loop-selftest.sh` inside the sandbox.** They create a scratch dir at the repo
root and their `trap ... EXIT` cannot delete it there, so it survives and every later run refuses to start —
and `pre-bash-policy-guard.js` blocks `rm -rf` outside scratch space **even after the user confirms in chat**,
so only the user can clear it. `loop-selftest` additionally fails inside the sandbox with a misleading assertion
message whose real cause is `git init` being denied its hook templates; `run-all.sh` now reports both classes as
BLOCKED rather than FAIL. Run the suite with the sandbox disabled, or from a clone in the session scratchpad.

**Measured gotchas (kept, each paid for):**
- **Never `git checkout -- <file>` to undo a mutation while that file holds uncommitted work.** It reverted a whole finished section; three "RED (good)" results in that run were the destruction, not the mutation. Copy the file aside and restore from the copy.
- Wrapping `agyask` in a `for` loop stops it matching `sandbox.excludedCommands`, so agy runs inside the sandbox and dies (`bind: operation not permitted`). Dispatch each call as its own bare command.
- Under `set -e`, `_x=$(cmd)` with non-zero `cmd` kills the script.
- Cross-provider token fold unavailable: agy and codex total unlike quantities. A9 folds within a provider only.

## 直近の作業

**Literature pass + A9/A10 upgrade (`89e51a5`, branch, unmerged)** — deep-research over multi-LLM ensemble
papers (report at `.babel/RESEARCH-ensemble-2026-08.md`, gitignored, 23 sources). Two findings were implemented:
- **A9 pairwise co-failure** (`by` replaces the `reporters` count; >=2 co-misses / 0 complementary
  catches over 4 entries splits a pair onto disjoint paths for 2 rounds) and **A10 MAST labels**
  (`mast` over the fixed 14-mode vocabulary). Both fully described in advanced.md §A9/§A10 and
  protocol.md §5 — do not re-derive them from here.

**Reviewed through the M acceptance gate, 2 rounds** (Claude Sonnet x2 blind + agy x3 parts + SOL normal;
then one SOL change-impact re-review). Round 1: 5 confirmed C/H, 4 refuted. Round 2: 3 more H, **every one in a
line round 1's fix had just written** — the first real A10 P4 entries (`.babel/process-failures.jsonl`, 3 records,
test A passes on all 3). The durable one: round 1 took an external finding's *conclusion* at face value instead of
re-deriving which half of the rule it actually broke. Details in the commit messages of `67dae92` / `e115636`.

**Round 3 was deliberately not run.** M's re-review fires exactly once and the rest goes to the user as
residual risk; running another round would make M a loop wearing M's clothes. So: **round 2's fixes are
unmeasured**, and the whole co-failure/split/MAST mechanism has run zero times in operation (N=0).

**Cost vs the 150-350k quoted at the crew proposal**: SOL r1 1.70M + r2 0.33M tokens, agy 92k over 3 parts,
Claude subagents 229k. An order-of-magnitude overshoot on SOL — quote SOL acceptance far higher next time.


## 次のタスク / 未解決

- **A10/A9 の新規分は M ゲートを通過済み**（上記）。ただしラウンド2の修正は未測定、運用実績 N=0。
- **A10 の天井（明記済み、未解決）**: repo スコープの記録は段4（`~/.claude/`）に構造上到達しない / Claude が Claude を律するルールを裁く循環はオフライン化で薄まるだけ / `rule.quote` と `prescribed` は帰属対象自身の自己申告 / テストAは存在証明であって注入証明ではない。
- **テスト実行経路を追加済み** (`tests/run-all.sh` + install.sh 配線, `c9b2cee`): 6本を1本から回し、走れなかった
  ものは BLOCKED/SKIP として**数えて名前を出す**（sandbox 拒否と scratch dir 残留を個別に検出）。install.sh からは
  optional check として呼ぶ。**CI 追加済み** (`.github/workflows/tests.yml`, merge `9950947`): push / pull_request で
  `run-all.sh --strict` を実行。`--strict` は not run が1本でもあれば exit 1（CI にはサンドボックスも残留 scratch dir も
  無いので BLOCKED は異常）。install.sh は `--strict` 無しのまま。実測: master run `32977143141` success, 9s, 6/6 PASS,
  0 not run。ubuntu-latest は node/python3 プリインストールで setup ステップ不要（`actions/checkout@v5`）。
  2つめのステップが `--strict` 自体を検査する: node を PATH から外して a6-selftest を SKIP にし、`--strict` が exit 1 /
  無指定が exit 0 の**両方**を assert（失敗側だけでは run-all.sh が別理由で落ちても通る）。master run `32977548487` success。
- **A6 harness** (`tests/a6-selftest.mjs`, `00d0d9c`): 30+ アサーション、mutation 6件 RED、A6 自身に欠陥なし。node 必要。
  **訂正: 「A6 は未テストだった」は誤り** — install.sh が既にブロックをパースし receipt gate を7ケース検証していた。
  未テストだったのは args ガード / void round / bracket / verify routing / rejection / cap 会計。commit `00d0d9c` の
  メッセージにこの誤りが残っている（push 済みのため訂正せず、`c9b2cee` で注記）。
- **測り直した context cost（前回セッションの誤読を訂正）**: `context-cost.py` が出すのは**バイト**で、~4 bytes/token。
  s-linear 58,123B ≈ 14.5k tokens / m-linear 97,575B ≈ 24k / l-loop 170,542B ≈ 43k。セクション単位の読み込みも既に
  モデル化済み。**「S は修正より規則のほうが大きい」は誤り** — 圧縮の優先度は低い。
- 旧来の未解決: A9 の reward に coverage 項が無い / severity が集約されない / CRB 外部ベンチ未実施 / source delay が (a) トラックを端から端まで覆っていない。詳細 `.babel/HANDOFF-next.md`（gitignored）。
- 未検証: A6 の reviewer/verifier 死亡、Windows 分岐、Fable5 チャネル。
