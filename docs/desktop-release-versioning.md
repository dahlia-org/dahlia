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
失敗時には v41 の状態にロールバックして再試行できる。以後の変更は後続の forward migration として追加する。

2026-09-11: `v42_localFirstSchema` 内の中間形式も整理した。Vault の再構築時に同期・復旧・イベント・外観の列を最終形で作成し、後続の列追加を省く。画像の OCR / caption は旧 screenshot 行から `file_text_bodies` へ直接保存し、一度 JSON metadata に格納してから取り出す変換と、画像 view / trigger の再書換えを省いた。公開済み v41 までの処理、画像原本の退避、本文・録音・翻訳の保存保証は維持する。

`v43_meetingCalendarSync` は meeting に同期用カレンダー working copy の nullable 列を追加する。端末固有の予定参照と公開済みデータは変更せず、Server からの値（明示的な null を含む）を保持して古いローカル予定による再送上書きを防ぐ。

旧 v42〜v54 を適用した開発・QA DB は配布対象外で、自動互換移行は設けない。
空の QA 環境ではアプリを終了して、対象の開発プロファイルの SQLite ファイルと WAL/SHM を退避してから再起動する。
`grdb_migrations` だけを書き換えて再適用しない。通常利用中の `Application Support/Dahlia` の DB はこの作業の対象外。

## Workspace 名称への移行（次回リリース）

未公開 v42 の改変を承認した上で、現行の Vault モデル・表示・API を Workspace に統一する。
v41 以前は維持し、v42 の一度のテーブル再構築後に SQLite の RENAME を使って
`workspaces`／`workspace_id` と関連する参照へ切り替える。公開済みデータの UUID・内容・出力パスを維持する。
詳細と検証範囲は [Workspace migration](workspace-migration.md) を参照。
