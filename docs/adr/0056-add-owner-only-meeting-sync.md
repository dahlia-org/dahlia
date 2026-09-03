# ADR-0056: owner-only の meeting sync を追加する

- Status: Accepted; Lakebase production rollout is gated by the Phase 0 probe
- Date: 2026-09-02
- Amends: ADR-0045, ADR-0052, ADR-0053
- Builds on: ADR-0043, ADR-0044, ADR-0049, ADR-0055

## Context

Dahlia の summary、transcript、screenshot を別マシンの Private Web と Server MCP から参照したい。
録音と文字起こしの正本は引き続き Mac に置き、同期停止や認証失効が録音・保存を妨げない一方向の付加機能にする。
PowerSync や Electric の双方向 change feed は片方向 upload に不要で、Swift attachment 経路と Lakebase logical replication の
追加制約を持ち込むため採用しない。

## Decision

- Vault ごとの明示設定で desktop から Server へだけ同期する。v1 は owner-only とし、Server から desktop への同期、共有、共同編集、
  権限管理は追加しない。既存 `accountConnectionId` は接続先として使うが、接続の選択だけでは同期を有効化しない。
- 同期対象は meeting の最小 metadata、summary document、transcript 原文、screenshot bytes、MIME、OCR text、AI caption。翻訳文は同期しない。
  音声、note、tag、calendar metadata、project context、音声特徴量は送信しない。
- PostgreSQL／Lakebase は全 sync table に `ENABLE` と `FORCE ROW LEVEL SECURITY` を適用する。所有者は既存 Artifact と同じ
  `owner_workspace_id = personal:<userId>` で、全 query は transaction-local `dahlia.workspace_id` を設定する `withIdentity` からだけ実行する。
  superuser または `BYPASSRLS` role では sync capability を公開しない。SQLite／D1 は同じ store API と明示 owner predicate を使う。
- client 生成の Vault、meeting、screenshot ID は canonical lowercase UUID として Server 全体で一意に扱う。複合 FK は
  `owner_workspace_id` を含む non-deferrable unique key を参照し、cross-owner parent 参照を構造的に拒否する。
- transcript は canonical content hash を generation とする。chunk を先に staging し、manifest 受理で active generation を切り替え、
  inactive generation を同一 transaction で削除する。staging meeting は manifest 受理まで read surface に出さない。
- screenshot object key は `meetings/{meetingId}/screenshots/{screenshotId}.{extension}` とし、extension は検証済み MIME から Server が決める。
  PNG、JPEG、WebP、GIF、TIFF だけを許可し、64 MiB 上限、immutable screenshot ID、CSP sandbox、`nosniff`、Range relay を適用する。
  bytes は既存 `ObjectStorage` backend を使うが Artifact table/API には入れない。
- durable desktop queue は録音・transcript persistence を待たせず、画像、transcript chunk、manifest の順に retry する。削除は画像25件ずつの
  再開可能処理とし、100件以上の meeting tombstone は drain ごとに一度だけ確認する。Dahlia の backup restore marker を検出した場合は
  Server Vault を削除して全件を再送する。
- Private Web と Server MCP は owner の同期済みデータだけを読む。検索は bounded な `LIKE`／`ILIKE` に留め、Server FTS／vector indexを持たない。
  Desktop は `api.sync.write`、MCP は `api.sync.read` を使用する。header proxy の MCP identity には read scope を合成する。
- Databricks Apps の service principal に `BYPASSRLS` は付かない。配備前に同じ role で
  `apps/server/scripts/lakebase-rls-probe.sql` を実行し、role属性、`set_config`、FORCE RLS、transaction後の非漏洩を確認する。
  失敗時は application-only 認可へ縮退せず、sync を配備しない。

## Consequences

- summary、transcript、screenshot、OCR text、AI caption は明示的に同期を有効化した Vault ではクラウド保存される。
  録音、文字起こし、閲覧、検索は同期の状態や Server 障害を待たない。
- header identity の owner key は `X-Forwarded-User`、無い場合は email に依存する。deployment の header 構成変更で owner ID が変わると、
  既存データが孤立して全件再同期が必要になる。
- Time Machine、Migration Assistant、SQLite 手動差し替えは既存 restore marker では検出できない。一括 tombstone の確認で誤削除を緩和する。
- Organization 共有は owner-only v1 の Lakebase 本番安定後に別 ADR で PRODUCT の team sharing／permission boundary を更新して実装する。
  それまでは header mode を含め全 deployment で owner-only を既定とする。

## Lakebase rollout record

2026-09-02 に `dahlia-dev` を Databricks Apps + Lakebase へ配備し、App service principal で sync capability が有効になること、
original-only transcript、manifest、screenshot upload／Range relay、read、Vault delete の一連の smoke test が成功することを確認した。
これにより non-superuser／`NOBYPASSRLS` role、transaction-local identity、FORCE RLS 下の owner read／write が実環境で成立した。
COMMIT／ROLLBACK 後の identity context 非漏洩は同じ pinned connection で起動時に検証する fail-closed probe を追加し、
更新版 Server の再配備後にも `sync: true` を確認した。これにより Phase 0 を完了した。
