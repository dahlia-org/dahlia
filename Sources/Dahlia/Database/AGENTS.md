# Database — GRDB スキーマとマイグレーション規約

SQLite の実体は `~/Library/Application Support/Dahlia/dahlia.sqlite`（`AppDatabaseManager.databaseURL`）。テストでは `AppDatabaseManager(path: ":memory:")` を使う。

## 絶対に破ってはいけないルール（マイグレーション）

- `migrator.eraseDatabaseOnSchemaChange = false` を変更しない。リリース済みユーザーの DB が破壊される。
- リリース済みの `registerMigration` ブロックは名前も中身も変更しない。スキーマ変更は必ず新しいマイグレーション（`v7_...` のように連番で命名）を末尾に追加する。
- カラム追加は既存の `add...ColumnIfNeeded` ヘルパーのパターンに倣い、冪等に書く。

## テーブル

`vaults`、`projects`（vault スコープ・パスベース）、`meetings`、`transcript_segments`、`tags`、`meeting_tags`、`notes`、`screenshots`、`summaries`、`action_items`、`calendar_events`、`instructions`

- すべての ID は UUID v7（`UUID.v7()`、時系列ソート可能）。
- `projects` はファイルシステム上のフォルダに対応し、`VaultSyncService`（FSEvents）が DB と同期する。

## 構成パターン

- `<Name>Record.swift`: 1 テーブル 1 ファイル。`Codable, FetchableRecord, PersistableRecord` に準拠した struct。
- `MeetingRepository`: `@MainActor` のクエリ集約層。UI からの読み書きはここを経由する。
