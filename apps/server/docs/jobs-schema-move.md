# 開発 PostgreSQL のジョブテーブル移動

未リリース Server の baseline を書き換えたため、適用済み DB に `pnpm db:migrate` を実行してもこの移動は行われない。Drizzle は適用済み migration 名で判定する。ledger の削除・再適用・hash の上書きは行わない。本番 migration と配備は対象外。

1. 対象 DB が `app.jobs_summary`、`app.jobs_image_analysis`、`app.jobs_search_index`、`app.jobs_storage_delete` を持つ変更直前の baseline であることを確認する。他の schema 差分がある DB にはそのまま適用しない。
2. API、Node worker、Workers のすべての書き込み元を停止し、処理中の transaction を終了させる。DB 全体の整合した backup を取得し、暗号化 master key は別の安全な場所で保持する。復元コピーで以下を検証してから、対象を明示して手動実行する。リセットや暗号文の再生成は不要。
3. 現在のテーブル owner（通常は migration/runtime 共通ロール）として `psql -v ON_ERROR_STOP=1` で下記 SQL を実行する。DB の CREATE 権限が必要。既存の `jobs` schema がある場合は先に用途・owner・ACL を確認し、この SQL を無条件に変更して続行しない。

```sql
BEGIN;
SET LOCAL lock_timeout = '5s';
CREATE SCHEMA jobs;
ALTER TABLE app.jobs_summary SET SCHEMA jobs;
ALTER TABLE jobs.jobs_summary RENAME TO summary;
ALTER TABLE app.jobs_image_analysis SET SCHEMA jobs;
ALTER TABLE jobs.jobs_image_analysis RENAME TO image_analysis;
ALTER TABLE app.jobs_search_index SET SCHEMA jobs;
ALTER TABLE jobs.jobs_search_index RENAME TO search_index;
ALTER TABLE app.jobs_storage_delete SET SCHEMA jobs;
ALTER TABLE jobs.jobs_storage_delete RENAME TO storage_delete;
-- PostgreSQL の暗黙の主キー名だけを新規 baseline と揃える。
ALTER TABLE jobs.summary RENAME CONSTRAINT jobs_summary_pkey TO summary_pkey;
ALTER TABLE jobs.image_analysis RENAME CONSTRAINT jobs_image_analysis_pkey TO image_analysis_pkey;
ALTER TABLE jobs.storage_delete RENAME CONSTRAINT jobs_storage_delete_pkey TO storage_delete_pkey;
COMMIT;
```

`SET SCHEMA` / `RENAME` はテーブル本体・行・OID・owner・テーブル ACL を保持し、索引・制約も移動する。外部キーの参照、RLS policy の列参照、RLS / FORCE RLS は維持される。job の status、attempts、available_at、claimed_at、lease_expires_at と全暗号文は書き換えない。明示的な外部キー・索引名は維持する。

標準構成はアプリロールが schema/table owner なので追加 GRANT は不要。別の既存ロールにジョブテーブル権限を付与している構成では、その同じロールに限って `GRANT USAGE ON SCHEMA jobs TO <既存ロール>` を上記 transaction の COMMIT 前に追加する。テーブル権限は維持されるため再付与しない。PUBLIC への grant や他ロールへの権限拡大は行わない。schema ごとの default privileges は移動されないため、将来作成するテーブル用の既存運用設定がある場合は `jobs` についても同じ対象ロール・最小権限で設定する。標準構成には default privileges 設定はない。

4. 更新版を起動する前に、backup/復元コピーと各テーブルの件数・主キー・全列を比較する。owner identity を transaction-local に設定して要約ジョブを検査し、`encrypted_payload`、`input_version`、`request_hash` の値が完全一致することを確認する。RLS を解除して比較しない。`pg_class` の `relrowsecurity` / `relforcerowsecurity` は `jobs.summary` で両方 true、他の3テーブルは従来どおり false。`pg_policies`、`pg_constraint`、`pg_indexes` とテーブル ACL も移動前と照合する（schema/物理名と上記3主キー名以外は同じ）。
5. 同じ暗号化キー設定の更新版で、既存要約ジョブの読取り・claim・再試行・キャンセルと期限切れ lease の再取得を復元コピー上で確認する。暗号化ポリシー、AAD の table 識別子、HMAC purpose は `jobs_summary` / `jobs_summary.inputVersion` / `jobs_summary.requestHash` のまま。settings・input・transcriptResult を再暗号化する必要はない。確認後に更新版の書き込み元を再開する。停止中に期限切れになった lease は従来の条件で再取得される。

失敗時は transaction を ROLLBACK して原因を確認する。commit 後に旧コードへ戻す必要がある場合も、全書き込み元を停止し、同じ transaction で上記 rename と schema 移動を逆順に戻す。暗号文・lease を変更しない。SQLite / D1 とコード上の `summaryJob` 等の名前は変更しない。
