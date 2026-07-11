# Database — GRDB とマイグレーション

この階層の最優先成果は、リリース済みユーザーの全データを保持したまま目的のスキーマへ移行できること。

本番 DB は `~/Library/Application Support/Dahlia/dahlia.sqlite`（`AppDatabaseManager.databaseURL`）にある。開発・テストからこのファイルを直接読み書きせず、`AppDatabaseManager(path: ":memory:")` または一時パスを使う。

## マイグレーションの不変条件

- `migrator.eraseDatabaseOnSchemaChange = false` を変更しない。破壊的なスキーマリセットは禁止する。
- 登録済みの `registerMigration` は、名前、順序、処理内容を変更しない。
- スキーマ変更は、現在の末尾を確認してから `v<次の番号>_<目的>` の新しいマイグレーションを末尾へ 1 つ追加する。固定の「次バージョン」を文書から推測しない。
- カラム追加は既存の `add...ColumnIfNeeded` パターンに従い、再実行しても安全な処理にする。
- 既存行の削除、テーブル再作成、値の不可逆変換が必要に見える場合は実装を止め、非破壊案と移行リスクを示して確認を取る。

## モデルとアクセス

- `<Name>Record.swift` は 1 テーブル 1 ファイルとし、`Codable`、`FetchableRecord`、`PersistableRecord` に準拠する。
- UI からの DB 読み書きは `@MainActor` の `MeetingRepository` を経由する。
- `projects` は vault 配下のファイルシステム上のフォルダに対応し、`VaultSyncService` が FSEvents から同期する。この対応関係をスキーマ変更で崩さない。

## 検証

- 新しいマイグレーションには、旧スキーマと既存行を用意し、移行後も値と関連が保たれることを確認するテストを追加する。
- 空の DB から全マイグレーションを適用する経路と、直前のスキーマから更新する経路の両方を確認する。
- 最低限 `swift test --filter AppDatabaseManagerTests` を実行し、変更対象に専用の migration / repository テストがある場合はそれも実行する。
