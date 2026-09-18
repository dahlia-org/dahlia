# AI Gateway と配布契約

対象: Server。採択: 2026-08-12〜08-14、backend モデル契約改訂: 2026-09-05。関連する認証・DB・配置の後続判断を反映。現在の API / 設定は [Server README](../../../apps/server/README.md) を参照する。

## Gateway 境界

固定版の Desktop 内蔵 Codex が使う任意の Responses 互換 Gateway を別 runtime に置く。provider secret と公開モデルを配置管理者が一元管理し、利用者へ secret を配布しない。Desktop の録音・保存・ローカル検索は Gateway、認証、provider の可用性を待たない。

- Codex API は `GET /api/v1/models` と `POST /api/v1/responses`。Chat Completions、汎用 Codex client、利用者 API key、compact、自動 provider fallback は提供しない。
- request / response を streaming relay し、prompt、画像、文字起こし、tool definition / output を設定済み provider に転送し得る。これらを relay の DB、cache、analytics、log、error report に保存しない。AI 利用を端末内処理と説明しない。
- 認証関連は `/api/**`、Better Auth protocol endpoint は `/api/auth/**` に分離し、認証開始 endpoint に既存 login を要求しない。`/healthz` は非機密の process liveness のみで、外部から無認証到達できる保証ではない。

accounts は Google sign-in と public-client OAuth、header は値を除去・上書きする trusted proxy と直接到達防止を使う。[共通 OAuth](../shared/oauth.md)、[Databricks identity](databricks.md)、[Database](database-and-identity.md)、[管理者](sharing-and-administration.md#server-管理者)、[timeout](../shared/ai-timeouts.md) を各境界の判断とする。

## Backend モデル契約

`AIGatewayBackend` は `listModels(request)` と `responses(body, context)` を持つ。共通の `RequestBody` は Responses API 形式、`RequestContext` は認証済み userId、headers、signal と Server が解決した任意の upstreamModel を持つ。backend は利用者情報を保持せず、上流ヘッダーを明示的に構築する。型と backend 実装は Worker-safe な package root で公開する。

モデル一覧の正本を環境変数 `DAHLIA_FOUNDATION_MODELS` へ移し、`/admin/models` と管理 API を廃止する。2026-09-06 の未リリース baseline 整理で、不要な Model Alias テーブル・CRUD・公開型と Gateway constructor の store 引数も削除した。全 backend はカンマ区切りの設定順でモデルを公開し、通常の Responses は列挙外の ID を拒否する。Server 所有の `codex-auto-review` override だけは設定された上流 ID を直接使う。各 JSON catalog が完全一致する slug の metadata を供給する。Databricks は `system.ai.*` の完全修飾 slug を公開し、その値を無加工で転送する。通常の Responses は利用者の OBO token を優先し、ない場合だけ App service principal の短期 token を使う。認証済み userId は Databricks request tags の user_id に設定する。OpenAI と Cloudflare も同じ列挙方式を使い、それぞれの native-ID JSON catalog を参照する。実行環境と AI 接続先を独立させ、Node のループと Workers Queues が共通の処理本体を呼び出す。Workers の正本 DB は PostgreSQL/Hyperdrive とし、Queue は参照通知、DB はリース・試行回数・結果を保持する。

`DAHLIA_CODEX_AUTO_REVIEW_MODEL` は backend の機能に依存しない Server 共通機能として維持する。設定時は予約 ID codex-auto-review の一覧と実行先を上書きし、環境変数の上流 ID を無加工で転送する。未設定・空の場合は backend の同名モデルを通常どおり一覧・推論に使用する。Databricks DAB は `DAHLIA_CODEX_AUTO_REVIEW_MODEL=system.ai.gpt-5-6-luna` を注入し、Model Service alias は登録しない。

Databricks DAB は `system.ai.*` モデルを直接設定し、postdeploy は Model Service を登録しない。既存の bundle 管理 AI schema は削除計画を避けるため維持する。設定の詳細は [デプロイ手順](../../../deploy/databricks/README.md#ai-models) を参照する。

### 理由と制約

モデル公開のために provider の discovery API や登録先 schema を管理する必要がない。一覧の可用性は process 設定だけに依存する。旧短縮名を利用するクライアントは新しい完全修飾 ID を選び直す必要がある。予約モデルの環境変数上書きは全 backend で維持される。

録音・文字起こし・Server canonical data の契約と、Responses の非永続化・streaming 境界は変更しない。

## 配布と拡張

`apps/server` は実行アプリ兼 `@dahlia-ai/server` package。macOS と独立した SemVer / `server-v<version>` tag で配布し、root export は Worker-safe、Node API は `/node` subpath に限定する。

backend extension は Better Auth plugin、認証前 route、認証済み API、session capability、Gateway 転送前 hook を追加できる。client extension はブランド、navigation、capability で保護した未予約 Dashboard route / React page を追加できるが、組み込み route は上書きしない。

Server migration を常に先、extension migration を後に合成し、各 ledger ID と SQLite の実行 filename を明示する。公開済み migration は不変。consumer は exact version、開発は `pnpm link`、公開物確認は `pnpm pack` を使う。extension contract の破壊的変更は major version を必要とする。

## 理由と制約

fork や機能別 provider adapter の重複を避ける代わりに、明示した hook / migration / version の互換性を管理する。Server は extension 固有の dependency、schema、設定、運用を所有しない。secret、request content、録音、Desktop DB を新しい共有 extension contract に含めない。

初期 Gateway は Personal workspace と AI 中継だけに限定した。後に採択された [Artifact（廃止）](artifacts.md)、[canonical sync](../shared/sync.md)、[共有](sharing-and-administration.md) は別の保存・認可境界であり、中継内容の永続保存禁止を解除しない。初期の root pnpm workspace と管理者 email table は、アプリ単位の依存管理と共通 Auth role に置き換わった。
