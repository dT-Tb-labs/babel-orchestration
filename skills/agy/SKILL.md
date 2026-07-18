---
name: agy
description: Use when user invokes /agy or asks for a second-opinion code review via Google Antigravity CLI (`agy`). Sibling of gemini-cli-review.
---

# Antigravity CLI クロスレビュー

Claude Code が書いたコードを Google Antigravity CLI (`agy`) に送り、独立した第二の視点でレビュー。
Claude とは異なる学習データ・推論パターンを持つ Antigravity (Gemini 3 系) の指摘を取り込み、
見落としたバグ・セキュリティ問題・代替アプローチを発見する。

`gemini-cli-review` と同じワークフロー。違い: CLI バイナリ + PTY wrapper 経由起動。

## 上流バグ #76 と回避策

`agy -p` は **非 TTY (subprocess / pipe / redirect) で stdout を silently drop or ハング** する ([upstream issue #76](https://github.com/google-antigravity/antigravity-cli/issues/76))。v1.0.2 時点未修正。

**回避策 (実装済):** [`agy_pty_wrapper.py`](agy_pty_wrapper.py) が pywinpty で ConPTY を確保し、その内側で agy を起動。agy の TTY 検出が成功し stdout が正常 flush される。動作確認済 (`PONG` 返却 ~30 秒)。

## 前提条件

### 1. `agy` バイナリ

```bash
agy --version 2>&1 || "$LOCALAPPDATA/agy/bin/agy.exe" --version 2>&1
```

Windows パス: `%LOCALAPPDATA%\agy\bin\agy.exe`（ユーザー名部分は環境依存）

### 2. 認証 (1 回のみ)

```powershell
agy auth login
```

PowerShell 起動 → ブラウザログイン。完了後永続。

### 3. PTY wrapper 依存

```bash
python -c "import winpty" 2>&1 || pip install pywinpty
```

`pywinpty` 必須。インストールされていなければ自動 install を試行。

## Step 1: レビュー対象の決定

**引数あり (`/agy <ファイルパス>`):**
- 指定ファイルを `Read` で読込

**引数なし (`/agy`):**
- 直近のセッションで Claude が編集・作成したファイル特定
- 複数なら全部読込 (多すぎる場合ユーザー確認)
- 特定不能なら「レビュー対象パスを教えてください」と尋ねる

## Step 2: PTY wrapper 経由で agy 起動

プロンプトは引数渡し。タイムアウトは wrapper 側 `--timeout` と Bash 側 `timeout` 両方設定:

```bash
python "$HOME/.claude/skills/agy/agy_pty_wrapper.py" \
  "You are an expert code reviewer providing a second opinion on code written by Claude AI. Your goal is to find issues that Claude might have missed and suggest alternative approaches from a fresh perspective.

Review the following code:

<filename>
[ファイル名]
</filename>

<code>
[コード内容]
</code>

Please evaluate:
1. Bugs and correctness issues (logic errors, edge cases, off-by-one errors)
2. Security vulnerabilities (injection, authentication issues, data exposure)
3. Code quality (readability, maintainability, naming, complexity)
4. Alternative approaches Claude might not have considered

Be concise and direct. Flag only meaningful issues, not minor style nitpicks. If the code looks good, say so." \
  --timeout 180
```

Bash ツール側 `timeout: 200000` (200 秒) を併用。

**プロンプト引数 escape:** プロンプト内にダブルクォートが多い場合、heredoc → 環境変数経由が安全:

```bash
PROMPT=$(cat <<'EOF'
You are an expert code reviewer...
EOF
)
python "$WRAPPER" "$PROMPT" --timeout 180
```

**モデル選択について:** `agy` には `-m` 相当のフラグ無し。CLI 側で固定 (現状 Gemini 3 系)。`gemini-cli-review` のような文字数別モデル切替はしない。

## Step 3: 結果の整理と表示

wrapper の stdout (ANSI 除去済) をパース。以下フォーマットで整理:

```markdown
## Antigravity クロスレビュー結果

**レビュー対象:** `<ファイル名>`

### 重要な指摘
(重要度順。なければ「指摘なし」)
- **[CRITICAL/HIGH/MEDIUM]** 指摘内容

### 代替アプローチの提案
(あれば記載。なければ省略)
- ...

### Claude からのコメント
(各指摘に対する Claude の判断。
 「正しい、修正必要」「現コンテキストでは問題ない、理由〜」など。
 見落としは率直に認める。)
```

## Step 4: 修正への誘導

「修正が必要」と判断した指摘があれば:
- 「〇〇を修正しますか？」と提案
- 承認後、通常の編集フローで修正

## トラブルシュート

| 症状 | 原因 / 対処 |
|------|------------|
| 出力が **`Python` の1語だけ**で即終了 (no review) | `python`/`python3` が **WindowsApps stub**(App実行エイリアス)で本物のインタプリタでない。**`python3.13`**(または `py -3.13`)で wrapper を起動する。本 SKILL のコマンド例の `python` は環境により要置換。 |
| wrapper exit 4 + "pywinpty not installed" | `pip install pywinpty` 実行 |
| wrapper exit 3 + "agy.exe not found" | `--agy-path` 指定 or インストール確認 |
| wrapper exit 2 + 空 stdout | agy が TTY 内でも応答せず。auth 期限切れ確認: `agy auth login` 再実行 |
| wrapper timeout (exit 2 + "Timeout after") | プロンプト巨大 or upstream 障害。`--timeout` 延長、`--print-timeout 5m` |
| ハング 200 秒超 | Bash 側 timeout 切れ。wrapper の `--timeout` 値が Bash timeout 未満か確認 |
| 日本語化け | wrapper は ANSI 除去のみ。文字化けは agy 出力側問題。プロンプトで「Reply in English」指定回避 |

## 出力例

```markdown
## Antigravity クロスレビュー結果

**レビュー対象:** `src/auth.py`

### 重要な指摘
- **[HIGH]** `verify_token()` でトークン有効期限チェック欠如
- **[MEDIUM]** パスワードハッシュに MD5 使用 (bcrypt/argon2 推奨)

### 代替アプローチの提案
- `PyJWT.decode()` は `exp` claim を自動検証する

### Claude からのコメント
有効期限チェック指摘は正しい。実装時の見落とし。
MD5 は既存システム互換のため意図的。新規パスワードは bcrypt 移行を検討。

修正しますか？ `verify_token()` に有効期限チェック追加可能。
```

## 実装ファイル

- [`agy_pty_wrapper.py`](agy_pty_wrapper.py) — pywinpty ConPTY wrapper (本スキル独自実装、bug #76 解消後も無害)
