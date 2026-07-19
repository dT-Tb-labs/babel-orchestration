# babel フェーズ別プレイブック

読者: babelを実行中のリードLLM。各節はSKILL.mdの各フェーズから参照される実行可能手順。通信規則・パケット形式・エラー処理は本ファイルでは再掲しない → **protocol.md 参照**。ここは「いつ・誰に・何を・どの順で投げるか」のみを扱う。

---

## debate-aggregation

Phase 1（設計）で使う。トリアージでM/Lと判定された場合のみ実施。Sは省略しリード単独設計。

0. **正典データチャネルの確定**（複製/データ系タスクのみ、設計より先）: 成果物が接地すべき一次資料と「劣化しない読み方」をこの段で決め、TaskPacketの `canon` 欄（protocol.md §2）に載せる。これを設計後・検収後に後付けすると、実装ワーカーが手近な劣化経路（画像OCRだけ・スクショ目視だけ）で埋めて欠落を作る（実タスクで観測したdefect根因）。以降の全実装/修理TaskPacketに `canon` を継承させる。データ系でないタスクはこのステップを飛ばす。
1. **並列発射**: superpowers:brainstorming でユーザー質疑を終えたら、リードが自案を書き始める**前に** SOL+agy へ同一のDesignPacket要求（TaskPacket, out_schema=DesignPacket。protocol.md §2）を `run_in_background` で同時発射する。
2. **アンカリング防止バリア**: リードは外部の応答を読まずに自案（DesignPacket相当）を書き切る。順序はコードでなく手順で保証する — 外部呼び出しの出力を待つ・確認するアクションは自案完成後に置く。
3. **L時のみ**: Claude内でも視点別（MVP-first / risk-first / user-first）の独立設計をWorkflowツールの `parallel()` でSonnet/Opus混成生成する（見取り図は acceptance-gate の雛形と同じ `agent()` API、schemaはDesignPacket形式）。
4. **統合**: 全案（自案＋SOL＋agy＋Claude内視点）を合意点マトリクス＋相違点にまとめる。
5. **相違の解消**: 系統間の相違はまずリードが接地（一次資料/実コード）で埋める。ドメイン最強モデルへの動的調停委任（algorithmic→SOL / API仕様→agy、相違点のみ送付）は `advanced.md` §A4。埋まらなければリードが最大深度で最終再考（SKILL.md「詰まったら最大深度思考」）→ なおダメならユーザーゲート「設計相違点」。

### SOL発射コマンド雛形

ペイロードは `.babel/<task>/inbox/design-req.json` に書き、SOLには `--cwd` 経由で自己読みさせる（protocol.md §3、argv上限回避）。SOLにはprotocol.mdポインタを使わず、出力形式を都度インラインで埋め込む（protocol.md §11）。

```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket at .babel/<task>/inbox/design-req.json. Read it and referenced files. Output DesignPacket JSON only: {approach:str, decisions:[str], risks:[str], tradeoffs:[str], rec:str}. Example: {\"approach\":\"JWT rotation via refresh token\",\"decisions\":[\"15min access TTL\"],\"risks\":[\"clock skew\"],\"tradeoffs\":[\"extra round trip\"],\"rec\":\"adopt\"}. No prose outside JSON."
```

- `--tier normal`（設計は normal、診断/重要検収は deep）。
- Bash `timeout: 600000`（cdx-sol SKILL.md必須。デフォルト120sでは長時間実行が殺される）＋ `run_in_background: true`。完了通知はagyと合わせて待ち合わせる。

### agy発射コマンド雛形

agyはfs読み不可（protocol.md §1）→ spec.mdへのパス参照はせず、spec要点（goal/criteria/constraints）をプロンプトにインライン化する。python3（stub環境ではpython3.13/py -3.13、SKILL.mdクルー表参照）＋heredoc環境変数方式（agy SKILL.md準拠、ダブルクォート事故回避）。ペイロードはdiffハンク相当のみに絞りサイズ上限を意識（超過時は要約して送る）。

```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"independent design for <task概要>. Spec要点: <spec.mdのgoal/criteria/constraintsを要約してここにインライン>","files":[],"inputs":[],"criteria":["<受入基準>"],"constraints":["<制約>"],"out_schema":"DesignPacket"}
Output DesignPacket JSON only, no prose. Do not use any tools — answer directly from the text given above.
EOF
)
python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 180
```

Bash側 `timeout: 200000` を併用（agy SKILL.md準拠）。

---

## build-debug

Phase 2（実装）で使う。superpowers:executing-plans / subagent-driven-development に接続する。babel固有の追加はチェックポイント検証とモデル割当のみ。

1. タスク分解後、機械的タスク（定型実装・置換・雛形埋め）は Sonnet サブエージェントへ委譲、中核ロジック（設計判断が要るコア実装）はリードが書く。
2. **カスケード**: Sonnetが一次ドラフト/スクリーニングを行い、通過分のみ上位モデル（リード/Opus）が精査する。全件を上位モデルに通さない。
3. **チェックポイント検証（任意）**: マイルストーン毎に SOL quick で spec-drift/bug チェック。**省略条件**: マイルストーンdiffがタスク最終changeset全体と一致する小タスクは省略し Phase 3検収に統合（二重発射回避）。機構・発射雛形は `advanced.md` §A3。
4. findingは finding-jsonl（protocol.md §2）で受理・schema検証ゲート（§7）。C/Hは即修正してから次へ、M/Lは記録し acceptance-gate で拾う。

**スタック時**（同一ファイル/シンボルで修正2回連続失敗）は `#sequential-switching` = `advanced.md` §A2（SOL deep→agy→リード最大深度→ユーザー）へ。

---

## sequential-switching

Phase 2スタック時（同一問題で修正2回連続失敗）の診断交代プレイブック → `advanced.md` §A2。

---

## acceptance-gate

Phase 3（検収）で使う。規模別の適用: **S=Claude敵対的レビュー1体のみ**（(a)を1体で実行、本節の残りは省略。外部が既に立っていればSOL quick可だが、小diffではSOL false positiveが出やすいのでClaude敵対を既定とする）。M=1ラウンド: 3系統レビュー(a)(b)(c)+リードのマージ・C/H修正まで。ステップ5の再実行ループ・収束判定・completeness criticはL専用。Mで修正後の確認は変更影響レビュアー1回のみ（修正diffと交差するスコープを持つ系統のうち元findingを報告した系統1つのみ再実行。複数該当時はSOL優先）。L=本節フル。編成はSKILL.md Phase 0参照。

**レビュー対象 = Phase 3開始時点の実changeset**（実際に編集したファイル一覧を `git diff --name-only` 等で確定する）。Phase 0トリアージ時に見積もったファイルリストではない — 実装中にスコープ外の共有モジュールを触っていれば、それも含める（agy査読#8）。

**CHANGESETの実体**: Phase 3開始時、リードが `.babel/<task>/inbox/changeset.diff`（unified diff）＋変更ファイル一覧を作成する。fs読み可能なレビュアー（SOL/Claudeサブエージェント）はパスで受領し、agyはハンクをインラインで受け取る。spec準拠レビューは `.babel/<task>/spec.md` を同様に配布する（agyには要点をインライン化）。

### 手順

1. changesetを確定し、3系統を発射する。
   - (a) Claude敵対的Workflow: リードがその場でWorkflowスクリプトを動的生成・実行（雛形は下記）。(a)のWorkflow敵対的検証はL専用。MではリードがAgent並列で簡略レビューし、Opus判定stageは使わない。**体数はdiffサイズ連動**（目安、行数はchangeset全体）: 50行未満=1体（全次元を1体でカバー）／50-200行=2体／200行超=3体（次元分割）。パイロット1実測: 44行diffに3体は過剰、1体に縮約。
   - (b) agy: changesetのdiffハンクをインラインでレビュー依頼。
   - (c) SOL normal: `.babel/<task>/inbox/` 経由でchangesetパスを渡しレビュー依頼。
   - (b)(c)は `run_in_background` で同時発射。(a)はリードのセッション内で実行。
2. **同ラウンド内レビュアー相互ブラインド**: (a)(b)(c)は互いのfindingを同ラウンド内で受け取らない。マージ・相互参照はリードのみが行う（protocol.md §8）。
3. 全系統のfindingが揃ったらリードがマージする（下記マージ手順）。
4. 系統間の相違はリードが接地で埋める（動的調停は `advanced.md` §A4）。
5. 収束条件を評価し、未収束なら該当レビュアーのみ再発射（変更影響ルーティング、protocol.md §9）。

### (a) Claude敵対的Workflow 雛形

次元別（correctness / security / edge-cases / spec準拠）を `pipeline()` で並列生成 → 各findingを敵対的検証（Sonnet一次生成 → Opus生死判定）。**(a)のWorkflow全文雛形（JS）は `advanced.md` §A6**。(a)のWorkflow敵対的検証はL専用。**MではリードがAgent並列で簡略レビュー**（Opus判定stageは使わない）。Workflowツールが無い環境も次元別レビューをAgent並列で代替。

### (b)(c) 雛形

(c) SOL: build-debugのチェックポイント雛形を流用し goalを検収用に変更。
```bash
node "$HOME/.claude/skills/cdx-sol/cdx-sol.mjs" --tier normal --cwd "<repo>" "TaskPacket: goal='full review of changeset', files=[{path:'<changesetファイルリストパス>'}], out_schema='finding-jsonl or NONE'. Output one JSON array per line: [\"<id>\",\"<sev C|H|M|L>\",\"<file>\",<line>,\"<claim>\",\"<evidence 15-30tok>\"]. Example: [\"F1\",\"C\",\"auth.py\",42,\"token expiry unchecked\",\"verify_token() decodes JWT without checking exp claim\"]. Output NONE (single word) if clean. No prose."
```
Bash `timeout: 600000` + `run_in_background: true`。L かつ セキュリティ/不可逆該当タスクの重要検収は `--tier deep` に差し替える（SKILL.mdコスト規律参照）。

(b) agy: PTY wrapper。changesetのdiffハンクをインラインで渡し、finding-jsonl形式行＋例1行をプロンプト内に含める（SOL同様インライン）。ペイロードはサイズ上限を意識し、超過時は分割または縮退する（設計雛形と同基準、protocol.md §3）。
```bash
PROMPT=$(cat <<'EOF'
TaskPacket: {"goal":"full review of changeset","files":[{"path":"<diffハンク要約>"}],"inputs":[],"criteria":["no C/H"],"constraints":["read-only"],"out_schema":"finding-jsonl"}
Diff hunk: <変更diffハンクをインライン貼付>
Output one JSON array per line: ["<id>","<sev C|H|M|L>","<file>",<line>,"<claim>","<evidence 15-30tok>"]. Example: ["F1","C","auth.py",42,"token expiry unchecked","verify_token() decodes JWT without checking exp claim"]. Output NONE (single word) if clean. No prose. Do not use any tools — answer directly from the text given above.
EOF
)
python3 "$HOME/.claude/skills/agy/agy_pty_wrapper.py" "$PROMPT" --timeout 240
```
Bash `timeout: 300000` + `run_in_background: true`。changeset全体レビューは設計依頼より重いためagyタイムアウトを240/300000に延長（意図的）。

### マージ手順

1. **指紋dedup**: `{path, シンボル（関数名/spec節ID）, 違反不変条件}` で照合。行番号はdedupキーに使わない（protocol.md §7）。照合はリードによる意味比較。
2. 既出リスト＋棄却済みリスト**両方**に対して照合する（再浮上ループ防止）。
3. C/Hのみ検証: 生存finding 8-12件/1呼びでバッチ化。repro実行可能なら再現コマンド/失敗テストで検証、不能なら不変条件論証で代替（protocol.md §7、repro安全規則も同節）。
   **小diffでのSOL findingは要接地確認**: changesetが小さい（目安50行未満）ほどSOL検収findingはfalse positive率が上がる（パイロット1実測: 実在しないtrailing whitespace指摘）。SOL単独findingかつ小diffの場合、検証段階で該当ファイルの実際の行を必ず確認してから採用する（他系統と一致するfindingは優先度を上げてよい）。S検収（SOL quick 1回のみ）でも同様に適用する。
4. 検証通過分を修正する。**修理前の再接地義務**: 監査findingをそのまま信じて修正しない。fixに着手する前に、該当箇所を一次資料（`canon` チャネル・実ファイルの当該行）で再確認し、findingの前提が実際に成立するか検証する。監査は誤検出しうる（パイロット2: R4系統が自発的に再接地して誤検出2件を防いだ）。修理TaskPacketには `constraints` に「fix前に canon で再接地し、finding前提を確認せよ」を必ず入れる。
5. **変更影響ルーティング**で再実行: 修正したファイル/関数が前回スコープまたは未解決findingと交差するレビュアーのみ再発射する（無関係レビュアーへの再送はしない）。
6. M/LはC/Hと同様に行出力させておくが検証・修正はしない。最終報告でまとめてユーザー提示。

### 終了条件

- **収束**: あるラウンドで新規C/Hゼロ、かつ直後の completeness critic（L専用、`advanced.md` §A5）も空。ラウンド1でクリーンなら即収束。修正が発生した場合のみ該当系統を再実行し、修正後ラウンドが新規C/Hゼロで収束。
- **上限（難度連動）**: 既定4ラウンド。**新規C/Hが毎ラウンド減り続けている間はcapを消費しない**（収束傾向なら+2まで自動延長、パイロット2の単一難所は7ラウンド要）。横ばい/発散ラウンドのみcapを1消費。延長時はユーザーに一言明示（想定トークン増含む）。cap到達前にリードが最大深度で最終再考を一度行う。なお新規C/Hが残れば残存findingをユーザー提示（ユーザーゲート「検収結果」/「残存リスク」）。
