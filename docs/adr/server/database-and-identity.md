# Server database と認可 identity

対象: Server。採択: 2026-08-28〜09-03。設定と migration の操作は [Server README](../../../apps/server/README.md)、実装規則は [Server guide](../../../apps/server/AGENTS.md) を参照する。

## Schema と migration

認証・管理・同期で DB を分けず、Drizzle の単一 application database に統一する。認証方式、DB、AI provider、storage の選択は独立させる。

- PostgreSQL / Lakebase は `auth`（生成 Better Auth）、`app`（Vault / Project、permission、meeting、transcript、screenshot、同期履歴）、`search`（文書・テキスト・vector）、`crypto`（wrapped Vault key）、`jobs`（summary / image_analysis / search_index / storage_delete）。検索 projection は `search.documents` に置き、`search → app → auth` の参照を持つ。検索データ全体は暗号化対象外だが、Vault 単位の RLS / FORCE RLS を適用する。ジョブは `jobs → app / auth` の参照を持つ。
- SQLite は Better Auth を top-level、Dahlia table は prefix なしにする。PostgreSQL の content ID は native UUID、非 UUID の user / workspace ID や hash は text。SQLite も境界で canonical UUID を検証する。
- Better Auth schema は生成物として手編集しない。全認証方式で Auth → application の順に migration を適用する。PostgreSQL の ledger は `drizzle.__dahlia_auth_migrations` と `drizzle.__dahlia_server_migrations` に分離し、SQLite は単一 baseline を使う。
- Node は SQLite / PostgreSQL / Lakebase、Workers は Hyperdrive / direct PostgreSQL を対象とする。D1はサポート対象から外し、専用adapter・migrationを配布しない。
- Lakebase は公式接続・OAuth refresh を再利用する。provider secret は DB に保存せず runtime secrets に置く。DB は認証と content を含む backup / retention / access-control の管理対象になる。

初期の `dahlia` 単一 schema と header-only application migration は、参照方向と認証方式間の一貫性を保つため変更した。当時の未リリース DB は再生成 baseline を使い、旧開発データを自動変換しなかった。released migration は不変で、以後は forward migration を追加する。

2026-09-06: Server canonical model では Vault / Project と meeting が同じ正本を構成するため、未リリースの `core` / `content` を `app` に統合した。SQLite は prefix を除去する。baseline を直接更新し、旧開発 DB からの自動移行は提供しない。認可、保持期間、再生成可否はスキーマではなく各テーブルの責務で区別する。

## リリース前 baseline 統合（2026-09-09、2026-09-12更新）

ユーザー承認により未リリース Server の開発履歴を現行 Drizzle schema から再生成した初期 migration に統合する。既存開発 DB の自動変換は提供せず、新しい空 DB への明示的な切り替えを必要とする。Desktop と既にリリースしたユーザー DB の migration は変更しない。

PostgreSQL は既存の生成 Auth baseline → application initial → runtime_support、SQLite は initial → runtime_support とする。Drizzle が生成した policy は参照先 identity function の後に作成するため runtime_support に置く。FORCE RLS、membership index、移管の DEFERRABLE 制約、SQLite FTS5 と trigger を維持し、旧テーブル作成・変換・backfill は除去する。snapshot は将来の差分生成用に保持し、配布 package は実行 SQL のみを含む。

2026-09-10: 初期リリース前のため、組織初期化記録、現行アカウント設定、検索のフィールド別重みも initial に統合した。旧設定の変換、既存組織の backfill、旧検索列からの再構築は提供せず、空 DB に現行スキーマと FTS を直接作成する。

2026-09-11: 未公開の `meetings.ical_uid`、`recurrence_id`、`calendar_event` と複合 index を Drizzle から再生成した initial に統合した。Auth initial と runtime_support の認可・FTS・移管制約は維持する。旧開発 DB の列追加履歴は配布せず、空 DB に最終 schema を直接作成する。

2026-09-12: 未公開の `transcript_segments.normalized_character_count` と PostgreSQL の OCR / caption 長制約を initial に統合した。空 DB には旧データの切り詰めが不要なため、全 owner を走査して一時テーブルへ補正値を準備する migration runner 専用処理も削除した。

以下の forward migration の説明は統合前の経緯であり、旧開発 DB からの移行保証ではない。リリース後は従来どおり forward-only とする。

## Header identity

proxy は client-supplied identity header を除去・上書きし、Server への直接到達を防ぐ。Server 側の CIDR 判定で代替しない。

Header mode でも `auth.user` を作り、`DAHLIA_AUTH_HEADER`（既定 `X-Forwarded-Email`）の検証・正規化済み email を `account.account_id` として request 開始時に内部 UUID へ JIT 射影する。`X-Forwarded-User` は使わない。name は更新し、email の変更は別 identity として自動統合しない。Better Auth runtime / Web sessionは両モードで有効にし、GoogleログインとOAuth provider endpointだけをaccounts限定にする。Header Web操作でもproxy identityを毎回確認し、Cookie本人との不一致を拒否する。

Header mode で管理者がユーザーを事前作成する場合も、作成 transaction 内で Header account と Personal/domain Organization を初期化する。後の proxy ログインはその account を参照し、既存の別認証方式のユーザーを email だけで自動統合しない。

`app.vault_permissions.granted_by_user_id` は `auth.user.id` を参照する。search jobはVault単位で、summary／image jobのuser IDはrequesterである。polymorphic な principal ID は type と組で扱い、単独の外部キーにしない。proxy の ID・認証方式変更による既存 permission の対応付けは自動化しない。

## Vault permission

`app.vaults.organization_id` が変更不能な所有Organizationを示す。削除はRESTRICTとし、`created_by {id,name,email}` は不変の監査snapshotとしてVault削除まで保持する。監査snapshotは通常APIやprincipal検索に公開しない。

`vault_permissions` のprincipalは `user | organization | team`、roleは `admin | editor | viewer`。有効roleはAdminを最優先とし、内容書込とVault管理を別predicateで評価する。Team権限はTeamと親Organizationの両membershipが必要。Organization所属だけではVaultアクセスを与えない。

PostgreSQL / Lakebaseはtransaction-local `app.user_id` と現在membershipをRLS / FORCE RLSで評価し、SQLiteも同じアプリpredicateを使う。permission自体へのRLSは自己参照再帰を避けて設定せず、認可済みstore以外へ公開しない。組織・Team・permission変更は共通アプリ検査と変更を一つのtransactionに含める。PostgreSQLは共通advisory lock、SQLiteはwriter transactionで同時変更を直列化し、最後のowner/member/Adminを守る。DBには形・参照整合性・RLS・FTSだけを置き、Organizationライフサイクルの業務ロジックをtriggerにしない。

## 経緯と制約

owner column と share table の重複を Vault permission に集約した。header mode で Auth schema を省く案は user 外部キーと migration 集合を分岐させたため撤回し、共通 user directory と生の user ID を採用した。organization ID 一覧を transaction context に渡す方式と `header_deployment` principal も廃止し、DB の現在 membership を参照する。

認証方式を同じ DB 上で切り替える identity 移行は対象外。permission table に新しい access path を足す場合は同等の認可境界が必要。

## Sync retention metadata（2026-09-06）

`app.sync_vault_state` は Vault と latest sequence / pruned boundary のみを保持する運用 metadata とし、既存 change ledger と同様に RLS の対象外とする。identity-scoped sync store と管理用 retention 処理以外へ公開せず、正本・receipt の認可は引き続き RLS と application 層で強制する。内容を追加する場合はこの例外を再評価する。

forward migration は既存 receipt 本文を保持したまま結果 ID / revision を抽出し、ledger と receipt の最大 sequence で Vault state を初期化する。PostgreSQL では migration owner が同一 transaction 内だけ receipt の FORCE RLS を解除して backfill し、完了前に復元する。保持処理は identity を transaction-local に設定し、失敗時は floor と削除を共に rollback する。

## アカウント設定と画像解析 job（2026-09-07）

`app.account_settings` は `auth.user.id` を正本キーに出力言語と解析言語範囲・一覧を保持する。本人の GET/PATCH だけを公開し、PostgreSQL は transaction-local identity と FORCE RLS、SQLite は user ID predicate で分離する。PATCH は指定項目だけの upsert、初回初期化は conditional INSERT。設定の競合制御用 revision は持たない。

`app.image_analysis_jobs` は file ID / Vault ID / requester user ID / model / lease / retry 状態だけの運用 metadata。既存の search job と同様に RLS の対象外とし、Node worker だけが利用する。画像・OCR・caption は queue に複製せず、identity-scoped store の認可と RLS を通して読取り・保存する。追加は forward migration で行い、既存の user / Vault / meeting / file を書き換えない。

OCR / caption の API 上限は OpenAPI `maxLength` の Unicode code point 数としてそれぞれ 32,768 / 1,024 とする。PostgreSQL は最終安全網として `app.files.metadata` と `search.documents` に 65,536 / 2,048 文字の制約を持ち、API validation を制約違反処理の代用にしない。SQLite には同じ DB 制約を追加しない。

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

PostgreSQL / Lakebase のジョブは `jobs.search_index`、`jobs.storage_delete`、`jobs.image_analysis`、`jobs.summary` に配置する。SQLite は `jobs_*`、Desktop の検索ジョブは `jobs_search_index` を維持する。要約ジョブの暗号化ポリシー・AAD・HMAC purpose は物理名から独立した既存の `jobs_summary` を維持する。未リリース Server の baseline を更新し、既存開発 DB は [データを保持する手順](../../../apps/server/docs/jobs-schema-move.md)で手動移行する。

`recordings` は `meeting_id` を外部キーとし、Vault は親会議から導出する。PostgreSQL RLS と共通 store の認可をともに親会議経由にし、API の `vaultId` は維持する。`meeting_events.vault_id` は会議削除後の履歴認可のため、`meeting_attachments.vault_id` は同一 Vault の複合外部キー制約のため維持する。

コンテンツ世代は `version`、同期・更新検出は `revision` とする。`account_settings.change_version` は `revision` に改名するが、項目単位の更新方法は維持し、CAS 必須にはしない。処理世代の generation、録音 UUID、解析方式・通信形式のバージョンは別概念として扱う。

## 初回組織登録（2026-09-12）

Header は設定されたメールヘッダーを外部 identity に使い、初回だけ domain Organization に参加する。[組織の決定](../shared/organization-vaults.md#organization)に従う。Personal の作成も共通初期化に含め、user 内の非公開 `registrationState`（Header は `domain`、Google は `personal`、完了後 `ready`）で中断を再開する。処理は transaction 内で行い、完了後の再ログインで脱退を取り消さず、参加履歴 table は設けない。

`server_settings` は SQLite の認可変更を直列化する singleton として保持し、廃止した Default 有効化列は持たない。PostgreSQL の advisory lock も維持する。

Better Auth runtime の `generateId` は UUIDv7 callback を使う。schema 生成だけは `generateId: "uuid"` とし、生成器が native uuid 型を選べるようにする。生成後に PostgreSQL の UUIDv4 default を除去し、runtime が ID を供給する。新規 mapping table は追加しない。
