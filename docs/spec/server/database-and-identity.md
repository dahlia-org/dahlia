# Server database と認可 identity

対象: Server。採択: 2026-08-28〜09-03。

Personal Organization、本人用 Workspace、登録時の作成方針は [Org配下の本人用Workspace](../shared/organization-personal-workspaces.md) に従う。設定と migration の操作は [Server README](../../../apps/server/README.md)、実装規則は [Server guide](../../../apps/server/AGENTS.md) を参照する。

## Schema と migration

認証・管理・同期で DB を分けず、Drizzle の単一 application database に統一する。認証方式、DB、AI provider、storage の選択は独立させる。

- PostgreSQL / Lakebase は `auth`（生成 Better Auth）、`app`（Workspace / Project、permission、meeting、transcript、screenshot、同期履歴）、`search`（文書・テキスト・vector）、`crypto`（wrapped Workspace key）、`jobs`（共通実行キュー `jobs.queue` と要約ジョブ）、`agent`（Mastra chat history）を持つ。検索 projection は `search.documents` に置き、`search → app → auth` の参照を持つ。検索データ全体は暗号化対象外だが、Workspace 単位の RLS / FORCE RLS を適用する。ジョブは `jobs → app / auth` の参照を持つ。
- Agent history は認証済み user UUID を Mastra の text `resourceId` へそのまま保存し、transaction-local `app.user_id` と直接比較する独立 RLS と migration ledger で管理する。chat は user 所有・既定 private で、作成時の Workspace を固定する。暗号化 Workspace は平文の履歴を作らず、page memory のみを使う。
- SQLite は Better Auth を top-level、Dahlia の table は prefix なしとする。PostgreSQL の content ID は native UUID、非 UUID の user / workspace ID や hash は text とする。SQLite も境界で canonical UUID を検証する。
- Better Auth schema は生成物として手編集しない。PostgreSQL / Lakebase は Auth → application → Agent の順に migration を適用する。PostgreSQL の ledger は `drizzle.__dahlia_auth_migrations`、`drizzle.__dahlia_server_migrations`、`drizzle.__dahlia_agent_migrations` に分離する。SQLite は単一 baseline を使う。
- Node は SQLite / PostgreSQL / Lakebase を対象とし、Workers は Hyperdrive / direct PostgreSQL を対象とする。D1 はサポート対象から外し、専用 adapter・migration を配布しない。
- Lakebase は公式接続・OAuth refresh を再利用する。provider secret は DB に保存せず runtime secrets に置く。DB は認証と content を含む backup / retention / access-control の管理対象である。

認可、保持期間、再生成可否はスキーマではなく各テーブルの責務で区別する。

### Migration の管理

- Server は未リリースである。Desktop の released migration は変更しない。
- 未リリース中は、ユーザー承認により migration を宣言 schema から再生成した baseline として直接編集し統合する（2026-09-23 に承認）。適用済み DB と ledger は自動変更しない。既存の開発 DB には自動変換を提供せず、現行 baseline を使うには DB を再作成する。検証には新しい空の DB を使い、保持する開発データの移行は別途扱う。
- Drizzle が生成した policy は参照先の identity function の後に作成するため、runtime_support に置く。
- 現在の application ledger は initial → runtime_support の 2 本、Agent ledger は initial → force_rls の 2 本である。SQLite は initial → runtime_support とする。
- 配布 package は実行 SQL のみを含む。snapshot は将来の差分生成用に保持する。
- リリース後は forward-only とする。

現在の baseline に含むもの:

- Dahlia Memory の projection（2026-11-05）と保存メモリーの `type` 列。Hindsight の退役表は宣言 schema にない。memory chunk の FORCE RLS（PostgreSQL）と FTS5 trigger（SQLite）は runtime_support に置く。Agent の ledger は変更しない。
- 大規模データ向けの index と RLS（2026-11-06）。RLS は `app.current_identity_workspace_ids(capability)` を非相関の scalar subquery で呼び、文ごとに 1 回（InitPlan）だけ評価する。`workspace_id` を持たない transcript・segment・summary・recording は、親の主キーで Workspace を引く相関 scalar subquery で判定する。`workspace_id` を各 segment に重複保持する案は採らない（[却下した案](#却下した案)）。外部キーの連鎖削除と移管更新に使う index として、`jobs.summary` の meeting / Workspace、`documents.meeting_id`、`meeting_events.owner_user_id`、receipt の owner と Workspace、`jobs.queue` の target と lease 中の行を持つ。
- Documents の index（2026-09-30）。Notes の検索条件に合わせ、復元履歴は `(document_id, id)`、presence は `(document_id, expires_at)` と `(workspace_id, expires_at)` で引く。Notes 本体の部分一意 index と更新ログの `(document_id, revision)` 主キーは保持する。
- 認可関数、全対象表の FORCE RLS、FTS、DEFERRABLE 制約、membership index。
- 旧 baseline を適用済みの DB は自動変換せず、新しい空の DB に作り直す。

## Header identity

proxy は client-supplied identity header を除去・上書きし、Server への直接到達を防ぐ。Server 側の CIDR 判定で代替しない。

Header mode でも `auth.user` を作り、`DAHLIA_AUTH_HEADER`（既定は `X-Forwarded-Email`）の検証・正規化済み email を `account.account_id` として request 開始時に内部 UUID へ JIT 射影する。`X-Forwarded-User` は使わない。name は更新し、email の変更は別 identity として自動統合しない。Better Auth runtime と Web session は両モードで有効にし、Google ログインと OAuth provider endpoint だけを accounts 限定にする。Header の Web 操作でも proxy identity を毎回確認し、Cookie 本人との不一致を拒否する。

Header mode で管理者がユーザーを事前作成する場合も、作成 transaction 内で Header account を初期化し、設定済みドメインの Organization へ member として参加させる。後の proxy ログインはその account を参照し、既存の別認証方式のユーザーを email だけで自動統合しない。

`app.workspace_permissions.granted_by_user_id` は `auth.user.id` を参照する。search job は Workspace 単位で、summary／image job の user ID は requester である。polymorphic な principal ID は type と組で扱い、単独の外部キーにしない。proxy の ID・認証方式変更による既存 permission の対応付けは自動化しない。

## Workspace permission

`app.workspaces.organization_id` が変更不能な所有 Organization を示す。削除は RESTRICT とし、`created_by {id,name,email}` は不変の監査 snapshot として Workspace 削除まで保持する。監査 snapshot は通常 API や principal 検索に公開しない。

`workspace_permissions` の principal は `user | organization | team`、role は `admin | editor | viewer` である。有効 role は Admin を最優先とし、内容の書込と Workspace 管理を別 predicate で評価する。Team 権限は Team と親 Organization の両方の membership を必要とする。Organization 所属だけでは Workspace へのアクセスを与えない。

PostgreSQL / Lakebase は transaction-local `app.user_id` と現在の membership を RLS / FORCE RLS で評価する。policy は読める・書ける・管理できる Workspace ID の配列を文ごとに 1 回求め、各行の `workspace_id` と照合する。SQLite も同じアプリ predicate を使う。permission 自体への RLS は自己参照再帰を避けて設定せず、認可済み store 以外へ公開しない。

組織・Team・permission の変更は、共通アプリ検査と変更を一つの transaction に含める。PostgreSQL は共通 advisory lock、SQLite は writer transaction で同時変更を直列化し、最後の owner / member / Admin を守る。DB には形・参照整合性・RLS・FTS だけを置き、Organization ライフサイクルの業務ロジックを trigger にしない。

## Sync retention metadata

`app.sync_workspace_state` は Workspace と latest sequence / pruned boundary だけを保持する運用 metadata とし、既存の change ledger と同様に RLS の対象外とする。identity-scoped sync store と管理用 retention 処理以外へ公開せず、正本・receipt の認可は引き続き RLS と application 層で強制する。内容を追加する場合は、この例外を再評価する。

保持処理は identity を transaction-local に設定し、失敗時は floor と削除を共に rollback する。

## Organization の登録・参加

Header は設定されたメール header を外部 identity に使い、初回だけ明示的に設定されたドメインの Organization に参加する。確認済み Google メールも同じ参加方式に従う。組織の決定は [Organization所有・共同編集](../shared/organization-personal-workspaces.md#organization) に従う。

user 内の非公開 `registrationState`（信頼済み Header と確認済み Google 登録は `domain`、その他は `personal`、初期化完了後は `ready`）で初期化の中断を再開する。処理は transaction 内で行う。完了後の再ログインで脱退を取り消さず、参加履歴 table は設けない。

`organization_domains` は組織とドメインの複合主キーと参加方式を持つ。`organization_join_requests` は pending の部分一意制約と処理履歴を持つ。いずれも共通 OrganizationStore が認可を検査し、設定・参加・申請処理と作成・削除を既存の認可ロックで直列化する（[Organization の参加方式](sharing-and-administration.md#organizationの参加方式と作成削除2026-09-14)）。

`server_settings` は SQLite の認可変更を直列化する singleton として保持する。PostgreSQL の advisory lock も維持する。

Better Auth runtime の `generateId` は UUIDv7 callback を使う。schema 生成だけは `generateId: "uuid"` とし、生成器が native uuid 型を選べるようにする。PostgreSQL の生成 default は持たず、runtime が ID を供給する。

## 設定の保存先

Web から開始する Server の処理設定は [文字起こし・要約の処理場所](../shared/transcription-summary-processing.md) に従い、Workspace の `generationSettings` と既存の revision / 管理者更新経路を使う。Desktop の生成設定の保存先と共有範囲は [アカウント別 Desktop 推論](../shared/account-scoped-desktop-inference.md) に従う。文字起こし言語とライブ文字起こしは Mac の端末設定に置き、DB の汎用 key/value、組織ポリシー、秘密情報には置かない。

Workspace 設定の更新は [同期の transaction と競合](../shared/sync.md#transaction-と競合) に従う。

コンテンツの世代は `version`、同期・更新検出は `revision` とする。処理世代の generation、録音 UUID、解析方式・通信形式のバージョンは別概念として扱う。

OCR / caption の API 上限は OpenAPI `maxLength` の Unicode code point 数として、それぞれ 32,768 / 1,024 とする。PostgreSQL は最終安全網として `app.files.metadata` と `search.documents` に 65,536 / 2,048 文字の制約を持つ。API validation を制約違反処理の代用にしない。SQLite には同じ DB 制約を追加しない。

画像・OCR・caption は queue に複製せず、identity-scoped store の認可と RLS を通して読み取り・保存する。

`recordings` は `meeting_id` を外部キーとし、Workspace は親の会議から導出する。PostgreSQL RLS と共通 store の認可をともに親会議経由にし、API の `workspaceId` は維持する。`meeting_events.workspace_id` は会議削除後の履歴認可のために、`meeting_attachments.workspace_id` は同一 Workspace の複合外部キー制約のために維持する。

要約ジョブの暗号化ポリシー・AAD・HMAC purpose は、物理名から独立した `jobs_summary` を維持する。Desktop の検索キューは `jobs_background` にある。

## Server 実行管理

### Server 実行管理の一本化（2026-10-03）

ユーザー承認により、全 Server ジョブの実行状態・lease・待機時刻・試行回数を `jobs.queue` に統合する。主キーは PostgreSQL の UUID / SQLite の text に保存する UUIDv7 とし、一意な `dedupe_key` で仕事の同一性を維持する。`dispatch_attempts` でインフラ障害・入力準備待ちを 3 回で DLQ へ移し、種類別の処理 `attempts` とは分離する。処理側の再試行・rate limit 待機では dispatch の予算をリセットする。`reference` は種類ごとの Zod schema で検証する `payload` に統一する。登録は正本更新と同じ接続・transaction の共有ヘルパーで行う。

`jobs.image_analysis`・`jobs.search_index`・`jobs.storage_delete`・`agent.memory_jobs` は廃止する。`jobs.summary` は公開 ID、暗号化入力、設定、stage、途中結果、冪等性情報と一意な queue 参照を保持し、owner RLS と暗号化 purpose を維持する。Memory の設定・進捗・入力世代・外部 operation と `agent.live_contexts` の資源ロックは専用テーブルに残す。queue の payload は本文や認証情報を含まない。

実行中の更新は ID と lease を維持して generation を増やす。古い結果は queue の ID・lease・generation・期限と、正本の revision / hash・認可で拒否する。結果保存と完了は原子的に行う。キャンセル後も有効な lease を並列数・target 排他に数える。種類別の再試行条件、owner 公平性、cooldown、最大 16 件の検索 batch、Node / Worker 共通の executor と起床通知を維持する。画像解析の自動受付範囲は広げない。

既存の開発 DB の変換は提供しない。Desktop キューは変更しない。

## 却下した案

- header mode で Auth schema を省く: user 外部キーと migration 集合が分岐するため。共通の user directory と生の user ID を採用する。
- workspace_id を各 segment に重複保持する: Workspace 移管で全 segment を書き換えるため。親の主キーで Workspace を引く。

## 制約

- 認証方式を同じ DB 上で切り替える identity 移行は対象外とする。
- permission table に新しい access path を足す場合は、同等の認可境界が必要である。
- チャットの共有は将来 thread 単位とする計画であり、共有機能、権限 table、Workspace 所有は未実装である。
- 既存の開発 DB への forward migration は提供しない。

## 未適合・未検証

- 未確定: 2026-09-30 の `summary_job_dispatch_select`（要約 worker が期限到来ジョブのある所有者を列挙する SELECT 専用 policy）が、2026-10-03 の共通キューへの統合後も有効か。
