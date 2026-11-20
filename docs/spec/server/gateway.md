# AI Gateway と配布契約

対象: Server。採択: 2026-08-12〜08-14。backend モデル契約: 2026-09-05 に改訂。Databricks のモデル一覧: 2026-10-03 に改訂。現在の API / 設定は [Server README](../../../apps/server/README.md) を参照する。

## Gateway 境界

固定版の Desktop 内蔵 Codex が使う任意の Responses 互換 Gateway を別 runtime に置く。provider secret と公開モデルを配置管理者が一元管理し、利用者へ secret を配布しない。Desktop の録音・保存・ローカル検索は Gateway、認証、provider の可用性を待たない。

- Codex API は `GET /api/v1/models` と `POST /api/v1/responses` である。Chat Completions、汎用 Codex client、利用者 API key、compact、自動 provider fallback は提供しない。
- request / response は streaming relay し、prompt、画像、文字起こし、tool definition / output を設定済み provider に転送し得る。これらを relay の DB、cache、analytics、log、error report に保存しない。AI 利用を端末内処理と説明しない。
- 認証関連は `/api/**`、Better Auth protocol endpoint は `/api/auth/**` に分離する。認証開始 endpoint に既存 login を要求しない。`/healthz` は非機密の process liveness のみを返し、外部から無認証到達できる保証ではない。

accounts は Google sign-in と public-client OAuth を使う。header は値を除去・上書きする trusted proxy と直接到達防止を前提とする。[共通 OAuth](../shared/oauth.md)、[Databricks identity](databricks.md)、[Database](database-and-identity.md)、[管理者](sharing-and-administration.md#server-管理者)、[timeout](../shared/ai-timeouts.md) を各境界の判断とする。

## Backend モデル契約

`AIGatewayBackend` は `listModels(request)` と `responses(body, context)` を持つ。共通の `RequestBody` は Responses API 形式、`RequestContext` は認証済み userId、headers、signal と Server が解決した任意の upstreamModel を持つ。backend は利用者情報を保持せず、上流ヘッダーを明示的に構築する。型と backend 実装は Worker-safe な package root で公開する。

モデルの公開方式は backend ごとに異なる。

- OpenAI と Cloudflare: 環境変数 `DAHLIA_FOUNDATION_MODELS` のカンマ区切りの設定順で公開する。通常の Responses は列挙外の ID を拒否する。各 JSON catalog が完全一致する slug の metadata を供給する。モデル一覧の管理 API は持たない。
- Databricks: 公開・順序・metadata・client version 判定・推論のモデル認可をプラットフォームに委ね（`/ai-gateway/codex/v1`）、[Databricks 配置と upstream identity](databricks.md#プラットフォームによるモデル公開管理) に従う。`client_version` は上流に渡し、Server はローカルで一覧を追加・削除しない。`system.ai.*` の完全修飾 slug を公開し、その値を無加工で転送する。通常の Responses は利用者の OBO token を優先し、ない場合だけ App service principal の短期 token を使う。認証済み userId は Databricks request tags の user_id に設定する。

OpenAI と Cloudflare は、それぞれの native-ID JSON catalog を参照する。実行環境と AI 接続先は独立させ、Node のループと Workers Queues が共通の処理本体を呼び出す。Workers の正本 DB は PostgreSQL（Hyperdrive）とし、Queue は参照通知、DB がリース・試行回数・結果を保持する。

予約 ID `codex-auto-review` の実行先は `DAHLIA_CODEX_AUTO_REVIEW_MODEL` で上書きできる。この機能は backend の機能に依存しない Server 共通機能である。設定時は環境変数の上流 ID を無加工で転送し、全 backend で維持する。未設定・空の場合は backend の同名モデルを通常どおり一覧・推論に使う。Databricks の一覧には Server が予約 entry を追加しない。Databricks DAB の既定値は `system.ai.gpt-6-luna` である。

Databricks DAB は `system.ai.*` モデルを直接設定し、bundle は Model Service を登録しない。bundle 管理の AI schema は削除しない。設定の詳細は [デプロイ手順](../../../deploy/databricks/README.md#ai-models) を参照する。

### モデル公開の理由と制約

OpenAI と Cloudflare では、モデル公開のために provider の discovery API や登録先 schema を管理する必要がない。一覧の可用性は process 設定だけに依存する。旧短縮名を利用するクライアントは、新しい完全修飾 ID を選び直す必要がある。

## 配布と拡張

`apps/server` は実行アプリ兼 `@dahlia-ai/server` package である。macOS と独立した SemVer / `server-v<version>` tag で配布する。root export は Worker-safe とし、Node API は `/node` subpath に限定する。

backend extension は Better Auth plugin、認証前 route、認証済み API、session capability、Gateway 転送前 hook を追加できる。client extension はブランド、navigation、capability で保護した未予約 Dashboard route / React page を追加できるが、組み込み route は上書きしない。

Server migration を常に先に、extension migration を後に合成し、各 ledger ID と SQLite の実行 filename を明示する。公開済み migration は不変である。consumer は exact version を指定し、開発では `pnpm link`、公開物の確認では `pnpm pack` を使う。extension contract の破壊的変更は major version を必要とする。

### 理由と制約

fork や機能別 provider adapter の重複を避ける代わりに、明示した hook / migration / version の互換性を管理する。Server は extension 固有の dependency、schema、設定、運用を所有しない。secret、request content、録音、Desktop DB は新しい共有 extension contract に含めない。

初期 Gateway は Personal workspace と AI 中継だけに限定した。Personal workspace の扱いは [Org配下の本人用Workspace](../shared/organization-personal-workspaces.md) に従う。録音・文字起こし・Server canonical data の契約と、Responses の非永続化・streaming 境界を維持する。canonical sync や共有など別の保存・認可境界の判断は、中継内容の永続保存禁止を解除しない。

## 却下した案

- Databricks のモデル一覧を `DAHLIA_FOUNDATION_MODELS` と JSON catalog で管理する: Databricks の表示モデル管理機能に合わせるため、この方式を廃止した。
