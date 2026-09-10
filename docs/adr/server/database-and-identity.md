# Server database と認可 identity

対象: Server。採択: 2026-08-28〜09-03。設定と migration の操作は [Server README](../../../apps/server/README.md)、実装規則は [Server guide](../../../apps/server/AGENTS.md) を参照する。

## Schema と migration

認証・管理・同期で DB を分けず、Drizzle の単一 application database に統一する。認証方式、DB、AI provider、storage の選択は独立させる。

- PostgreSQL / Lakebase は `auth`（生成 Better Auth）、`app`（Vault / Project、permission、job、meeting、transcript、screenshot、検索 projection、同期履歴）。参照方向は `app → auth`。
- SQLite / D1 は Better Auth を top-level、Dahlia table は prefix なしにする。PostgreSQL の content ID は native UUID、非 UUID の user / workspace ID や hash は text。SQLite / D1 も境界で canonical UUID を検証する。
- Better Auth schema は生成物として手編集しない。全認証方式で Auth → application の順に migration を適用する。PostgreSQL の ledger は `drizzle.__dahlia_auth_migrations` と `drizzle.__dahlia_server_migrations` に分離し、SQLite / D1 は単一 baseline を使う。
- Node は SQLite / PostgreSQL / Lakebase、Workers は D1 / Hyperdrive / direct PostgreSQL を対象とする。DB 接続可能性と個別 capability の有効性は別であり、D1 sync の制限を解除したとは扱わない。
- Lakebase は公式接続・OAuth refresh を再利用する。provider secret は DB に保存せず runtime secrets に置く。DB は認証と content を含む backup / retention / access-control の管理対象になる。

初期の `dahlia` 単一 schema と header-only application migration は、参照方向と認証方式間の一貫性を保つため変更した。当時の未リリース DB は再生成 baseline を使い、旧開発データを自動変換しなかった。released migration は不変で、以後は forward migration を追加する。

2026-09-06: Server canonical model では Vault / Project と meeting が同じ正本を構成するため、未リリースの `core` / `content` を `app` に統合した。SQLite / D1 は prefix を除去する。baseline を直接更新し、旧開発 DB からの自動移行は提供しない。認可、保持期間、再生成可否はスキーマではなく各テーブルの責務で区別する。

## リリース前 baseline 統合（2026-09-09、2026-09-10更新）

ユーザー承認により未リリース Server の開発履歴を現行 Drizzle schema から再生成した初期 migration に統合する。既存開発 DB の自動変換は提供せず、新しい空 DB への明示的な切り替えを必要とする。Desktop と既にリリースしたユーザー DB の migration は変更しない。

PostgreSQL は既存の生成 Auth baseline → application initial → runtime_support、SQLite / D1 は initial → runtime_support とする。Drizzle が生成した policy は参照先 identity function の後に作成するため runtime_support に置く。FORCE RLS、membership index、移管の DEFERRABLE 制約、SQLite FTS5 と trigger を維持し、旧テーブル作成・変換・backfill は除去する。snapshot は将来の差分生成用に保持し、配布 package は実行 SQL のみを含む。

2026-09-10: 初期リリース前のため、組織初期化記録、現行アカウント設定、検索のフィールド別重みも initial に統合した。旧設定の変換、既存組織の backfill、旧検索列からの再構築は提供せず、空 DB に現行スキーマと FTS を直接作成する。

以下の forward migration の説明は統合前の経緯であり、旧開発 DB からの移行保証ではない。リリース後は従来どおり forward-only とする。

## Header identity

proxy は client-supplied identity header を除去・上書きし、Server への直接到達を防ぐ。Server 側の CIDR 判定で代替しない。

Header mode でも `auth.user` を作り、検証済み `X-Forwarded-User`、未指定なら正規化 email を ID として request 開始時に JIT 射影する。name / email は更新するが、同じ email の別 ID は自動統合せず拒否する。Better Auth runtime / session / OAuth endpoint は accounts mode だけで有効にする。

`app.search_index_jobs.owner_user_id` と `app.vault_permissions.granted_by_user_id` は `auth.user.id` を参照する。polymorphic な principal ID は type と組で扱い、単独の外部キーにしない。proxy の ID・認証方式変更による既存 permission の対応付けは自動化しない。

## Vault permission

`app.vault_permissions` を ownership と read sharing の唯一の正本とする。principal は `user | organization | team`、role は `owner | member`。user principal は生の user ID を使い、OAuth の `personal:<userId>` workspace claim と混ぜない。

- Vault ごとに変更不能な user owner を1件だけ持ち、constraint と partial unique index で保証する。Vault と owner permission は同じ transaction で作る。
- content に owner を重複保存せず、親子関係は Vault ID で制約する。非 owner の write / delete / permission mutation は存在を開示しない404。owner 移譲、member write、直接 user member の作成 API は追加しない。
- PostgreSQL / Lakebase は transaction-local `app.user_id` から permission と `auth.member` / `auth.team_member` を評価し、context 未設定時は deny。membership 削除を即時反映し、owner の read/write は維持する。共有の有効化条件は [共有](sharing-and-administration.md#共有境界) に従う。
- Vault / content / 検索 projection は RLS と application 認可を併用する。SQLite / D1 は同じ predicate を application 層で強制する。table owner や BYPASSRLS の挙動も配置時に検証する。
- permission table 自体への RLS は自己参照再帰を避けて設定しない。identity transaction 内の sync store と organization / Team cleanup だけが認可して利用し、汎用 query surface へ公開しない。
- API は `/api/v1/vaults/{vaultId}/permissions`。read model は有効な複数経路のうち owner を優先して `role: owner | member` を返す。

## 経緯と制約

owner column と share table の重複を Vault permission に集約した。header mode で Auth schema を省く案は user 外部キーと migration 集合を分岐させたため撤回し、共通 user directory と生の user ID を採用した。organization ID 一覧を transaction context に渡す方式と `header_deployment` principal も廃止し、DB の現在 membership を参照する。

認証方式を同じ DB 上で切り替える identity 移行は対象外。permission table に新しい access path を足す場合は同等の認可境界が必要。

## Sync retention metadata（2026-09-06）

`app.sync_vault_state` は owner / Vault と latest sequence / pruned boundary のみを保持する運用 metadata とし、既存 change ledger と同様に RLS の対象外とする。identity-scoped sync store と管理用 retention 処理以外へ公開せず、正本・receipt の認可は引き続き RLS と application 層で強制する。内容を追加する場合はこの例外を再評価する。

forward migration は既存 receipt 本文を保持したまま結果 ID / revision を抽出し、ledger と receipt の最大 sequence で Vault state を初期化する。PostgreSQL では migration owner が同一 transaction 内だけ receipt の FORCE RLS を解除して backfill し、完了前に復元する。保持処理は identity を transaction-local に設定し、失敗時は floor と削除を共に rollback する。

## アカウント設定と画像解析 job（2026-09-07）

`app.account_settings` は `auth.user.id` を正本キーに出力言語と解析言語範囲・一覧を保持する。本人の GET/PATCH だけを公開し、PostgreSQL は transaction-local identity と FORCE RLS、SQLite は user ID predicate で分離する。PATCH は指定項目だけの upsert、初回初期化は conditional INSERT。設定の競合制御用 revision は持たない。

`app.image_analysis_jobs` は file ID / Vault ID / owner user ID / model / lease / retry 状態だけの運用 metadata。既存の search job と同様に RLS の対象外とし、Node worker だけが利用する。画像・OCR・caption は queue に複製せず、identity-scoped store の認可と RLS を通して読取り・保存する。追加は forward migration で行い、既存の user / Vault / meeting / file を書き換えない。

## アカウント設定の機能別集約（2026-09-08）

個人ごとに1行を維持し、共通の `output_language`、画像解析の `analysis_languages`、要約の `summary` に分ける。
要約 JSON は `method`・共通の `detail`・方式別の `methodSettings`（model / reasoningEffort）を保持する。
汎用 key/value、組織ポリシー、秘密情報、端末設定はこの table に含めない。

PATCH は指定された末端項目だけを DB の現在行に適用し、同じ項目は後勝ちとする。画像解析の scope / identifiers は一体で置換する。
内部 `change_version` は値が変化した更新でだけ増やし、SSE の変更検知専用とする。競合チェックには使わず API に公開しない。

移行は新列追加、選択中の方式の詳細度と両方式の model / reasoningEffort の移行、旧3列の削除を forward migration で行う。
FORCE RLS は backfill transaction 内だけ解除し commit 前に復元する。旧 API 形式は維持せず Desktop / Web / Server を同時更新する。
既存 summary job と履歴の設定は移行しない。

2026-09-10の[文字起こし・要約の処理場所](../shared/transcription-summary-processing.md)により、要約JSONの現行形式は
`{ mode, remote: { detail, model, reasoningEffort, transcriptionModel? } }`へ置き換えた。追加のforward migrationは旧`transcript`を
`local`、旧`cloudTranscription` / `audio`を対応する`remote`設定へ変換する。PATCHの末端更新、内部revision、既存job保持の原則は維持する。

## 運用テーブルと番号の整理（2026-09-09）

ジョブテーブルは `jobs_search_index`、`jobs_storage_delete`、`jobs_image_analysis`、`jobs_summary` に統一する。Desktop の検索ジョブも `jobs_search_index` とする。既存ジョブの状態を保持する追加 migration を使う。

`recordings` は `meeting_id` を外部キーとし、Vault は親会議から導出する。PostgreSQL RLS と共通 store の認可をともに親会議経由にし、API の `vaultId` は維持する。`meeting_events.vault_id` は会議削除後の履歴認可のため、`meeting_attachments.vault_id` は同一 Vault の複合外部キー制約のため維持する。

コンテンツ世代は `version`、同期・更新検出は `revision` とする。`account_settings.change_version` は `revision` に改名するが、項目単位の更新方法は維持し、CAS 必須にはしない。処理世代の generation、録音 UUID、解析方式・通信形式のバージョンは別概念として扱う。

## 既定組織の初期化記録（2026-09-10）

accounts mode の既定組織は、組織・ユーザーに外部キーを持たない `server_initializations` の `default_organization` 行で一度だけ初期化する。記録、組織、初期 owner を同じ PostgreSQL / SQLite transaction または D1 batch で保存し、明示的な組織削除後も記録を残す。forward migration は既存の `external` 組織を記録し、名前・所有権・membership を変更しない。

この table は処理名と初期化日時だけの運用 metadata として RLS 対象外とし、認証 store 以外へ公開しない。header mode の JIT projection は従来どおり維持する。

Better Auth runtime の `generateId` は UUIDv7 callback を使う。schema 生成だけは `generateId: "uuid"` とし、生成器が native uuid 型を選べるようにする。生成後に PostgreSQL の UUIDv4 default を除去し、runtime が ID を供給する。新規 mapping table は追加しない。
