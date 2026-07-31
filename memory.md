# Project Memory
最終更新: 2026-07-31

## 現在の状態

master、commit `c7c3faa`、origin と同期済み（push 済み）。
babel スキルを babel 自身で 8 ラウンド叩き、**49件を確定・修正 / 21件をグラウンディングで棄却**。

全チャネル稼働、**サンドボックス弱体化ゼロ・per-call フラグ不要**:
- SOL → `solask`（`~/.local/bin`）
- agy → `agyask`（`~/.local/bin`）
- 両方 `sandbox.excludedCommands` で外に出る

## 設定 (`~/.claude/settings.json`)

```json
"env": { "CLAUDE_PLUGIN_DATA": "/tmp/claude/codex-inline" },
"sandbox": {
  "enabled": true,
  "excludedCommands": ["agyask", "agyask *", "solask", "solask *"],
  "filesystem": { "allowWrite": ["~/.codex"] },
  "network": { "allowedDomains": ["chatgpt.com","*.chatgpt.com","api.openai.com","auth.openai.com"] }
}
```

**`excludedCommands` は permission-rule 構文** — `"cmd"` だけでは引数付き呼び出しにマッチしない。`"cmd *"` が必須。同型の罠は `Bash(cmd *)` 系全般。

## この回で分かったこと（再発見コスト高）

**シムが必要な理由（両チャネル共通）**: サンドボックス内では nested `sandbox-exec` が張れず（`sandbox_apply: Operation not permitted`）、agy は localhost bind と Go の TLS 検証も落ちる。専用コマンド名にすることで excludedCommands の対象にできる。

**トークン肥大の実測値**: A6 受入テンプレの旧構造（finding 1件ごとに Opus 検証者 / M/L も検証 / 各検証者に入力全部を再送）は **2.12M tokens で confirmed 3件**。同期間の SOL は **171k で 42件**。約250倍差。修正後の実測は 57行の差分で **2エージェント・126k**。

**チャネル別 reward（8ラウンド実測）**: SOL 42 confirmed / 1 refuted、agy 9/4、Claude workflow 3/16。SOL の false positive がほぼゼロなのは想定外に強い。

**`ptyprocess` は PEP 668 でシステム pip 不可** → `~/.local/share/babel/agy-venv`（install.sh が作る。`$DEST` は install のたび消えるので外に置く）。

## 次のタスク / 未解決

- Fable5 チャネル未検証（リードモデル切替はスキルからは不可）。
- install.sh の venv 生成が check-then-act（並行実行でレース）。L 判定、実害想定なし。
- 8ラウンドの作業記録は `.babel/babel-doc-hardening/`（gitignore 対象）。scoreboard・rejected fingerprint・各ラウンドの raw 出力あり。セッション終了で消えて構わない。
