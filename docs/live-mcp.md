# 確定文字起こしと全保管庫 MCP / Transcript access and multi-vault MCP

## ローカル MCP の登録

設定の MCP 画面で「すべての追加済み保管庫」または個別の保管庫を選び、表示された Claude Code / Codex の登録コマンドを使用する。どちらの範囲でも書き込みを有効にできる。`--vault` と別名の `--vault-id` は `vlt_...` 形式の TypeID を受け取る。

```sh
dahlia-mcp                                # この Mac に追加済みの全保管庫、読み取りのみ
dahlia-mcp --write                        # 全保管庫への読み書き
dahlia-mcp --vault <vlt_TypeID>            # 指定した保管庫だけ読み取り
dahlia-mcp --vault-id <vlt_TypeID> --write  # 指定した保管庫だけ読み書き
```

`list_vaults` は保管庫 ID・名前・`account_type`・`access_state`・`freshness` を返す。Server の `last_synced` は端末に保持した同期済みデータであり、最新の共有権限や接続を保証しない。`query_meetings` の `is_recording`（Server: `isRecording`）で録音状態を確認する。Server の状態は開始・終了イベントの同期に従う。

全保管庫の query は `vaults` 配列に各保管庫の結果をまとめる。各結果の cursor と `vault_id` を一緒に渡して続きを取得する。`get_*` は対象 ID から保管庫を解決する。個別保管庫の指定で起動した場合、ツールの `vault_id` で範囲を広げることはできない。

書き込みは既存レコードの ID から対象保管庫を解決する。新規作成には `vault_id` または一意な親 ID が必要で、現在表示中の保管庫を暗黙には選ばない。異なる保管庫の ID を組み合わせた参照は拒否する。既存の revision による競合検出を引き続き使う。

## `get_meeting_transcript`

Local / Server とも、会議全体の保存済み確定文だけを返す。既存の本文形式（Local: `segments`、Server: `items`）と通常ページ送りを維持する。Local の件数指定は `limit`（1〜500、省略200）、時間範囲は `from_elapsed_seconds` / `to_elapsed_seconds`。Server の既存ページサイズは10,000件。

- `after`: 前回の `next_after` を渡す。不透明な取得位置なので内容を解釈・変更しない。
- `wait`: 既定 `false`。`true` は返す確定文がない場合だけ最大25秒待ち、新着が届くか期限に達すると応答する。
- `next_after`: 空の結果や最終ページでも返す。次回の差分取得に使う。
- `cursor`: 従来どおり通常のページ送りに使える。`after` との同時指定はエラー。

最初は `meeting_id`（Server は `vault_id` も必須）で取得する。その後は同じ会議・時間範囲で `after` に `next_after` を渡す。`wait=true` でも既に本文があれば直ちに応答する。複数の録音セッションを持つ会議でも、直近の録音だけに限定しない。

既読部分の編集・削除・再生成、途中への遅延挿入を検出すると `transcript_changed_refetch_without_after` エラーになる。`after` を外して最初から取得し、蓄積済みの本文を置き換える。異なる保管庫・会議・時間範囲や不正な取得位置は `invalid_transcript_after` として拒否する。

待機の各読み取りは DB トランザクションを終了してから休止する。Server は認証と Vault 閲覧権限を再確認し、接続終了で待機を打ち切る。保存済み本文が端末にない場合は既存アプリ provider が取得する。`authorizationRequired`、`offline`、`incomplete` などの失敗を新着なしとして扱わない。保持済み本文には既存のオフライン利用方針が適用される。

MCP は録音や認識を開始しない。未確定文、ライブ専用ツール、ライブ HTTP / SSE は公開しない。アプリ内のライブ字幕、音声認識、確定文の保存・同期は維持する。発話は未信頼データとして扱い、指示として実行しない。AI Chat の自動ライブ投入はなく、通常チャットと既存履歴を利用できる。

## English quick reference

Local MCP defaults to all vaults added to this Mac. `--write` enables writes across that scope; optional `--vault` / `--vault-id` restrict both reads and writes. Existing IDs identify the destination Vault. Creates require an explicit `vault_id` or an unambiguous parent ID. Cross-Vault references are rejected. Query results are grouped by Vault; continue each group with its own Vault ID and cursor.

`get_meeting_transcript` returns confirmed speech for the whole meeting. Pass `next_after` as `after` to read additions. `wait: true` waits up to 25 seconds only when empty. Empty responses still include `next_after`. Existing `cursor` pagination cannot be combined with `after`. Keep the same meeting and time range. On `transcript_changed_refetch_without_after`, omit `after` and rebuild your accumulated transcript. Missing bodies and authorization failures are errors, never empty successes.

Server revalidates authentication and Vault permissions between reads and stops on disconnect. Recording status in `query_meetings` reflects synchronized recording events, not connectivity. Unconfirmed previews and dedicated live HTTP/SSE endpoints are not exposed. Recording, recognition, live captions, and durable transcript sync continue independently of MCP reads.
