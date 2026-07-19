# ADR-0007: SQLite バックアップをスキーマ世代付きで管理する

## Status

Accepted

## Date

2026-07-18

## Context

Dahlia のミーティング、文字起こし、設定参照の中心データは SQLite にある。ユーザーが世代を識別して手動で退避・復元でき、
古いリリースのバックアップも登録済み migration を通して利用できる必要がある。一方、未文字起こし音声を含む録音ファイルは
大きく、SQLite と別の lifecycle を持つため、DB バックアップへ含めない。

## Decision

- バックアップは `Application Support/Dahlia/Backups` に、ユーザーが削除するまで世代数の上限なく保存する。
- 各 SQLite に、形式バージョン、世代 UUID、作成日時、schema version、migration identifier、アプリ version/build、作成理由を
  `dahlia_backup_metadata` として埋め込む。
- 音声ファイルはコピーしない。新旧の音声参照テーブルはバックアップの SQLite snapshot から削除し、録音セッションの timeline と
  文字起こし結果は維持する。
- segmented audio が未文字起こしのセッションは、文字起こしまたは明示的な破棄が終わるまで作成・復元を拒否する。
  読み取り不能になった旧 single-file 音声参照はバックアップ時に除外する。
- インポートは管理領域の一時ファイルへコピーした後に integrity、metadata、migration 履歴を再検証し、原子的に世代へ追加する。
- 復元前に現在DBの安全バックアップを作る。古い既知 schema は staging 上で最新へ migration する。未知の新しい schema、改変された
  schema、追加 trigger/view、integrity 不良は拒否する。
- 復元は再起動時、単一プロセス lock の取得後かつ通常のDB接続前に行う。現行DBの WALをcheckpointし、元DBを recovery として保持した
  まま検証済みコピーへ切り替える。中断を検出した次回起動では recovery を優先して元に戻し、処理を再試行可能にする。

## Scope

対象は Dahlia の SQLite のみ。次はバックアップ対象外とする。

- BatchAudio と旧 Vault 音声ファイル
- Vault 内の Markdown、添付ファイル、その他のファイルシステム内容
- UserDefaults
- Keychain、認証トークン

## Consequences

- SQLite と文字起こしデータは、表示された schema 世代を確認して復元できる。
- 音声、Vault、OS設定、認証情報の完全な端末移行には別のバックアップ手段が必要になる。
- 復元にはアプリ再起動が必要で、録音中は開始できない。
- 世代数を自動削減しないため、ユーザーが設定画面から容量と不要世代を管理する。
