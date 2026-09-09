# Desktop Release Versioning

- Apply this policy prospectively when preparing a release. Do not revise or validate historical version numbers, missing releases, or build numbers against it.
- Keep `CFBundleShortVersionString` in `x.y.z` format. Determine the next version from the complete set of changes since the latest release, not from each individual change.
- Increment `z` for a release containing only backward-compatible fixes, improvements, or additions. This includes bug fixes, internal refactoring, documentation, backward-compatible features, and additive database migrations that do not change the meaning of existing data, such as new tables or indexes and nullable or defaulted columns.
- Increment `y` and reset `z` to `0` when a release changes compatibility, a primary workflow, or an existing behavioral or data contract. This includes semantic changes to recording or transcription, changes to existing settings, MCP or backup contracts, table rebuilds, renames or removals, type, nullability, constraint, or relationship changes, and migrations that reinterpret, transform, or meaningfully backfill existing data.
- When a release contains changes from multiple categories, use the highest required increment.
- Never infer an `x.0.0` release. Increment `x` and reset `y` and `z` to `0` only when the user explicitly requests a major version; ask before release if a major increment appears necessary.
- Update versions during release preparation, not as part of ordinary feature or fix changes.
- Treat `CFBundleVersion` as an integer build number independent of the marketing version. Increase it from the latest published build for every newly published distribution artifact, including a replacement with the same marketing version. Local builds and unpublished attempts do not require an increment.
- During release preparation, update `CFBundleShortVersionString` and `CFBundleVersion` together in `Resources/Info.plist`.

## v0.21.0 以降の未配布 DB マイグレーション

v0.21.0（2026-09-01、`a2bb5d3b`）の最終マイグレーションは `v41_vaultAISettingsBackfill`。
次のリリースでは、未配布だった v42〜v54（v51 の2件を含む）を `v42_localFirstSchema` に統合した。
v41 以前の登録名・順序・処理は維持し、公開版からの更新と新規 DB の作成は同じ経路を使う。
同期キューは最終形式で作成し、既存の会議・録音・画像・本文の変換を単一トランザクションで適用する。
未終了の旧 realtime 録音は保存済み duration、最終発話時刻、セッション更新時刻の順で終了時刻を補完する。
終了済み録音と batch 音声の復旧状態は維持し、会議の合計録音時間を再計算してから本文の生成時刻を補完する。
失敗時には v41 の状態にロールバックして再試行できる。以後の変更はこの統合版の末尾へ追加する。

旧 v42〜v54 を適用した開発・QA DB は配布対象外で、自動互換移行は設けない。
空の QA 環境ではアプリを終了して、対象の開発プロファイルの SQLite ファイルと WAL/SHM を退避してから再起動する。
`grdb_migrations` だけを書き換えて再適用しない。通常利用中の `Application Support/Dahlia` の DB はこの作業の対象外。
