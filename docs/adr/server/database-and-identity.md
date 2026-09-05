# Server database と認可 identity

対象: Server。採択: 2026-08-28〜09-03。設定と migration の操作は [Server README](../../../apps/server/README.md)、実装規則は [Server guide](../../../apps/server/AGENTS.md) を参照する。

## Schema と migration

認証・管理・同期で DB を分けず、Drizzle の単一 application database に統一する。認証方式、DB、AI provider、storage の選択は独立させる。

- PostgreSQL / Lakebase は `auth`（生成 Better Auth）、`app`（Vault / Project、permission、artifact metadata、job、meeting、transcript、screenshot、検索 projection、同期履歴）。参照方向は `app → auth`。
- SQLite / D1 は Better Auth を top-level、Dahlia table は prefix なしにする。PostgreSQL の content ID は native UUID、非 UUID の user / workspace ID や hash は text。SQLite / D1 も境界で canonical UUID を検証する。
- Better Auth schema は生成物として手編集しない。全認証方式で Auth → application の順に migration を適用する。PostgreSQL の ledger は `drizzle.__dahlia_auth_migrations` と `drizzle.__dahlia_server_migrations` に分離し、SQLite / D1 は単一 baseline を使う。
- Node は SQLite / PostgreSQL / Lakebase、Workers は D1 / Hyperdrive / direct PostgreSQL を対象とする。DB 接続可能性と個別 capability の有効性は別であり、D1 sync の制限を解除したとは扱わない。
- Lakebase は公式接続・OAuth refresh を再利用する。provider secret は DB に保存せず runtime secrets に置く。DB は認証と content を含む backup / retention / access-control の管理対象になる。

初期の `dahlia` 単一 schema と header-only application migration は、参照方向と認証方式間の一貫性を保つため変更した。当時の未リリース DB は再生成 baseline を使い、旧開発データを自動変換しなかった。released migration は不変で、以後は forward migration を追加する。

2026-09-06: Server canonical model では Vault / Project と meeting が同じ正本を構成するため、未リリースの `core` / `content` を `app` に統合した。SQLite / D1 は prefix を除去する。baseline を直接更新し、旧開発 DB からの自動移行は提供しない。認可、保持期間、再生成可否はスキーマではなく各テーブルの責務で区別する。

## Header identity

proxy は client-supplied identity header を除去・上書きし、Server への直接到達を防ぐ。Server 側の CIDR 判定で代替しない。

Header mode でも `auth.user` を作り、検証済み `X-Forwarded-User`、未指定なら正規化 email を ID として request 開始時に JIT 射影する。name / email は更新するが、同じ email の別 ID は自動統合せず拒否する。Better Auth runtime / session / OAuth endpoint は accounts mode だけで有効にする。

`app.search_index_jobs.owner_user_id` と `app.vault_permissions.granted_by_user_id` は `auth.user.id` を参照する。polymorphic な principal ID は type と組で扱い、単独の外部キーにしない。proxy の ID・認証方式変更による既存 permission の対応付けは自動化しない。

## Vault permission

`app.vault_permissions` を ownership と read sharing の唯一の正本とする。principal は `user | organization | team`、role は `owner | member`。user principal は生の user ID を使い、Artifact / OAuth の `personal:<userId>` workspace claim と混ぜない。

- Vault ごとに変更不能な user owner を1件だけ持ち、constraint と partial unique index で保証する。Vault と owner permission は同じ transaction で作る。
- content に owner を重複保存せず、親子関係は Vault ID で制約する。非 owner の write / delete / permission mutation は存在を開示しない404。owner 移譲、member write、直接 user member の作成 API は追加しない。
- PostgreSQL / Lakebase は transaction-local `app.user_id` から permission と `auth.member` / `auth.team_member` を評価し、context 未設定時は deny。membership 削除を即時反映し、owner の read/write は維持する。共有の有効化条件は [共有](sharing-and-administration.md#共有境界) に従う。
- Vault / content / 検索 projection は RLS と application 認可を併用する。SQLite / D1 は同じ predicate を application 層で強制する。table owner や BYPASSRLS の挙動も配置時に検証する。
- permission table 自体への RLS は自己参照再帰を避けて設定しない。identity transaction 内の sync store と organization / Team cleanup だけが認可して利用し、汎用 query surface へ公開しない。
- API は `/api/v1/vaults/{vaultId}/permissions`。read model は有効な複数経路のうち owner を優先して `role: owner | member` を返す。

## 経緯と制約

owner column と share table の重複を Vault permission に集約した。header mode で Auth schema を省く案は user 外部キーと migration 集合を分岐させたため撤回し、共通 user directory と生の user ID を採用した。organization ID 一覧を transaction context に渡す方式と `header_deployment` principal も廃止し、DB の現在 membership を参照する。

認証方式を同じ DB 上で切り替える identity 移行は対象外。permission table に新しい access path を足す場合は同等の認可境界が必要。`app.artifact` の RLS 免除は認可/storage metadata だけを owner-scoped API から扱う条件に限る。

## Sync retention metadata（2026-09-06）

`app.sync_vault_state` は owner / Vault と latest sequence / pruned boundary のみを保持する運用 metadata とし、既存 change ledger と同様に RLS の対象外とする。identity-scoped sync store と管理用 retention 処理以外へ公開せず、正本・receipt の認可は引き続き RLS と application 層で強制する。内容を追加する場合はこの例外を再評価する。

forward migration は既存 receipt 本文を保持したまま結果 ID / revision を抽出し、ledger と receipt の最大 sequence で Vault state を初期化する。PostgreSQL では migration owner が同一 transaction 内だけ receipt の FORCE RLS を解除して backfill し、完了前に復元する。保持処理は identity を transaction-local に設定し、失敗時は floor と削除を共に rollback する。
