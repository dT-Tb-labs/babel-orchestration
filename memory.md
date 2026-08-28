# Project Memory
最終更新: 2026-08-28

## 現在の状態

master pushed, tree clean (`git log --oneline -1` for where — a hash written here is stale by the
next commit, including the one that writes it). CI runs `run-all.sh --strict` on push/PR.

**Verification: `sh skills/babel/tests/run-all.sh` — 6 passed, 0 failed, 0 not run** (outside the
sandbox, and on every CI run). Paths: install.sh (lenient), CI (`--strict`).

**HARDWARE HAZARD, 2026-08-27 — MLX kernel-panics this Mac.** Three hard panics (08-26 19:36,
08-27 00:12, 08-27 15:49 JST), all identical: `panic: "Memory object not found in fMemoryCountedSet
or fPendingMemorySet" @IOGPUGroupMemory.cpp:281`, watchdog reset, machine-wide power-off. Known
Apple IOGPUFamily bug that MLX triggers (mlx#3346, exo#1972); no macOS update exists. Trigger is
**MLX/Metal generally**, not LM Studio or qwen — a peer session drives `mlx.core` directly and its
runs died in the same panics. Whether one MLX workload suffices or two concurrent are needed is
UNDETERMINED (the deciding evidence was erased by the reboot). Read panic times from the
`Epoch Time: Calendar:` field, never the header/filename — those are next-boot WRITE times and were
off by up to 10.5h. Cross-check with `last reboot` / `last shutdown`, an independent instrument.
**Never leave a multi-run result only in a session scratchpad** — one panic erased a finished 12-call
audit. Durable dir + per-call flush + skip-completed resume.

**Measured gotchas (kept, each paid for):**
- **Never `git checkout -- <file>` to undo a mutation while that file holds uncommitted work.** It reverted a whole finished section; three "RED (good)" results that run were the destruction, not the mutation. Copy the file aside and restore from the copy.
- **Never run `gate-selftest.sh` / `loop-selftest.sh` in the sandbox.** They leave a scratch dir at the repo root that only the user can clear, and `loop-selftest` fails there with a misleading assertion whose real cause is `git init` being denied hook templates. `run-all.sh` reports both as BLOCKED, not FAIL.
- **Never edit a shell script while it is running.** bash resumes at a stale byte offset and dies at a nonsense line (`line 194: ,: command not found` on a curl header). Copy it aside for multi-run work.
- Wrapping `agyask` in a `for` loop stops it matching `sandbox.excludedCommands`, so agy runs inside the sandbox and dies (`bind: operation not permitted`). Dispatch each call as its own bare command.
- Under `set -e`, `_x=$(cmd)` with non-zero `cmd` kills the script.
- `printf '--foo'` — bash printf parses the leading `--` as an option. Reword or use `printf '%s\n'`.
- Cross-provider token fold unavailable: agy and codex total unlike quantities. A9 folds within a provider only.
- **Cost**: the M acceptance gate on A9/A10 cost SOL 2.03M tokens against a 150-350k quote. Quote SOL acceptance an order of magnitude higher.

## 直近の作業

**CI** (`.github/workflows/tests.yml`) and **A6 harness** (`tests/a6-selftest.mjs`) done and green.
**agy pinned to `gemini-3.7-flash-high`** (`0d2fdf2`, Flash-only tier) — `AGY_MODEL` overrides;
an unknown id exits 1 with the model list, no silent fallback. Verified by asking agy its own id.
**A9 co-failure + A10 MAST labels** (`d192f28`) — read advanced.md §A9/§A10 and protocol.md §5, not
here. Passed the M gate over 2 rounds; round 2 found 3 H defects, **every one in a line round 1's fix
had just written** — round 1 took an external finding's *conclusion* instead of re-deriving it.

**qwen audit of `skills/babel/tests/` (08-27)** — 12 calls (`review` + `silent-failure` x 3 language
bundles x 2 runs), 19 raw findings, **0 confirmed defects**. The top-5 clusters all trace to
deliberate design whose reason is in a comment directly above the quoted line. Recorded because a
clean result is worth exactly as much as a dirty one and stops the next reader re-running it.
Outputs: `~/Claude/.babel/qwen-audit/`. Docs NOT audited — cross-file rule contradictions need
SOL/agy or the lead, not qwen.

## 次のタスク / 未解決

- **LESSON (user, 2026-08-27): adding a local LLM to this Mac destabilised it — do not put one back without a reason that outweighs a machine-wide crash.** Stated precisely, because the loose version misleads: the trigger is **MLX/Metal**, not qwen, and what qwen added was the largest single GPU allocation on the box (15GB resident, ctx 42496, parallel 4). Watermelon's ASR + 4B scorer are also MLX and were live in 2 of the 3 panics. **So removing qwen did NOT make the machine safe** — it removed one firing path of several, and the remaining one is the user's own main app.
- **Qwen3.8-27B IS DELETED FROM THIS MACHINE (08-27, user's call).** Both builds gone (LM Studio GGUF + hub manifest by the user; the MLX build and a duplicate GGUF by me), 47GB reclaimed. **The `/qwen` skill is deleted too** (`~/.claude/skills/qwen/` and `~/.claude/scripts/claude-qwen.sh`); the full measurement record was archived first to `~/Claude/.babel/qwen-SKILL-archived-20260827.md` — read that before rebuilding anything qwen-shaped. Watermelon's ASR/scorer models (`~/Claude/dev/Watermelon/models/`, `~/.cache/huggingface/`) were NOT touched and are intact.
- **If qwen is ever reinstalled, the runtime decision is already made and measured: `llama-server`, NOT LM Studio.** LM Studio + MLX cannot turn thinking off at all (1199/1199 tokens to reasoning, no answer) and silently ignores `-c` (forces 42496). LM Studio + GGUF fixes `-c` (32768 honoured, qwenask needs NO code change) but **leaks chain-of-thought into `content`** — the reply fills with "Wait, let's look closer / Let's re-evaluate" and never completes a finding; 5m05s for 2.3k in / 2k out. `llama-server` from `~/.lmstudio/extensions/backends/llama.cpp-mac-arm64-apple-metal-advsimd-2.29.1/` has a real `--reasoning off` (verified: 0 reasoning chars, 4/4 runs), honours `-c`, and matched MLX recall (3,3,4,3 vs 4,5,3,3 of 6 at 14k input). Adopting it needs qwenask retargeted to OpenAI `/v1/chat/completions` and a supervisor. Model file: `lmstudio-community/Qwen3.8-27B-GGUF`, Q4_K_M, sha256 `e00082f779fa385cee8c68a3ec8833a75778cc87272240b942f74e0b8243e520` — **always verify the hash**: LM Studio's own downloader produced a size-correct, hash-WRONG file once, and its `useHFProxy` (now `false`, backup kept) stalled at 0 B/s where HF-direct ran at 28-38 MB/s.
- **Standing objective (user, 2026-08-26)**: babel exists to solve complex tasks with **Claude + SOL + agy — three bodies** — at the best solution *and* efficiently. That lineup is the **M** scale. Judge every proposal against it.
- **Structural misalignment (2026-08-26)**: every adaptive/measured mechanism (A9 fold, co-failure split, A10 scoreboard) is **L-only**. So the target 3-body configuration is exactly the one babel never learns from. Per-task data at M *is* too thin; a cross-task ledger is what would make M-scale learning possible.
- **次の一手（手順書は PILOTS.md 末尾 "Next tuning pass"）**: on the next real M task, write the lead's own findings to `results/lead-solo-r1.jsonl` **before** dispatching SOL/agy, then diff against grounded confirmed. Zero extra dashes. If the crew's marginal yield is ~0, "three bodies do not pay" becomes the first measurement.
- **A9/A10 は M ゲート通過済み。ラウンド2の修正は未測定、運用実績 N=0。A10 の天井（未解決）**: repo スコープの記録は段4（`~/.claude/`）に構造上到達しない / Claude が Claude を律するルールを裁く循環はオフライン化で薄まるだけ / `rule.quote` と `prescribed` は帰属対象自身の自己申告 / テストAは存在証明であって注入証明ではない。
- **context cost**: `context-cost.py` outputs BYTES (~4 bytes/token); s-linear ≈ 14.5k tokens / m-linear ≈ 24k / l-loop ≈ 43k. "S rules cost more than the fix" was a misreading — compression is low priority. 旧来の未解決: A9 の reward に coverage 項が無い / severity が集約されない / CRB 外部ベンチ未実施 / source delay が (a) トラックを端から端まで覆っていない。未検証: Windows 分岐、Fable5 チャネル。詳細 `.babel/HANDOFF-next.md`（gitignored）。
- memory.md は public repo で追跡対象。コスト実績も未解決欠陥もそのまま公開される。
