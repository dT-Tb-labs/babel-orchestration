# Project Memory
Last updated: 2026-07-31

## 現在の状態
- master clean、origin: dT-Tb-labs/babel-orchestration（push は未実施）。
- このMac (darwin) で babel 全チャネル稼働: Opus5 / Sonnet5 / codex 0.146.0 (cdx-sol、sandbox内) / agy 1.1.8 (sandbox外、自動)。
- **sandbox の弱体化はゼロ、per-call フラグも不要。**

## 設定 (`~/.claude/settings.json`)
```json
"env": { "CLAUDE_PLUGIN_DATA": "/tmp/claude/codex-inline" },
"sandbox": {
  "enabled": true,
  "excludedCommands": ["agyask", "agyask *"],
  "filesystem": { "allowWrite": ["~/.codex"] },
  "network": { "allowedDomains": ["chatgpt.com","*.chatgpt.com","api.openai.com","auth.openai.com"] }
}
```
- `CLAUDE_PLUGIN_DATA`: codex-companion の state/jobs 書込先 (既定 `~/.claude/plugins/data/` は sandbox deny)。
- `allowWrite: ~/.codex`: codex の sqlite state 初期化。
- `excludedCommands`: agy シムを sandbox 外へ。

## 最重要の発見: excludedCommands は permission-rule 構文
**`"agyask"` だけでは引数付き呼び出しにマッチしない。`"agyask *"` が必須。**
これに気付くまで「効いたり効かなかったり」に見えていた (引数なし probe は成功、引数付き実呼び出しは失敗していただけ)。同型の罠は `Bash(cmd *)` 系のルール全般にあるはず。

## agy の技術メモ (2026-07-31 調査)
sandbox 内では3つ同時に詰む: PTY 確保不可 (`out of pty devices`)、localhost bind 拒否 (ローカル language server)、Go バイナリの TLS 検証失敗 (`x509: OSStatus -26276`)。
- upstream #76 の stdout drop は **stdin が open pipe のときだけ**。`< /dev/null` で PTY 不要 (コミュニティ製 bridge 2種はどちらも PTY 方式で sandbox では無効)。
- `SSL_CERT_FILE` 不可 — darwin の Go は Security.framework を使い env を見ない。
- `enableWeakerNetworkIsolation` なら sandbox 内でも動くが trustd exfil 経路が全 sandbox コマンドに開くため不採用。

## 次のタスク / 未解決
- 再起動後の確認: `env.CLAUDE_PLUGIN_DATA` が効き cdx-sol が素の呼び出しで通るか (今セッションはインライン env で検証)。
- `agyask` シムは install.sh 未対応。他機へ配る場合は agy SKILL.md 記載の内容から手動作成 + excludedCommands 追記。
- Fable5 チャネル未検証。
