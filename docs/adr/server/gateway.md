# AI Gateway と配布契約

対象: Server。採択: 2026-08-12〜08-14。関連する認証・DB・配置の後続判断を反映。現在の API / 設定は [Server README](../../../apps/server/README.md) を参照する。

## Gateway 境界

固定版の Desktop 内蔵 Codex が使う任意の Responses 互換 Gateway を別 runtime に置く。provider secret と公開モデルを配置管理者が一元管理し、利用者へ secret を配布しない。Desktop の録音・保存・ローカル検索は Gateway、認証、provider の可用性を待たない。

- Codex API は `GET /api/v1/models` と `POST /api/v1/responses`。Chat Completions、汎用 Codex client、利用者 API key、compact、自動 provider fallback は提供しない。
- Model Alias は application DB から単一 upstream の model ID へ対応付ける。`default` を特別扱い・自動作成しない。管理者は alias、表示名、upstream model、有効状態を管理し、接続先と secret は runtime 設定だけで変更する。
- provider 未設定でも認証・管理 UI は起動し、モデル一覧は空、Responses は明示的に失敗する。モデル解決は DB の可用性に依存する。
- request / response を streaming relay し、prompt、画像、文字起こし、tool definition / output を設定済み provider に転送し得る。これらを relay の DB、cache、analytics、log、error report に保存しない。AI 利用を端末内処理と説明しない。
- 認証関連は `/api/**`、Better Auth protocol endpoint は `/api/auth/**` に分離し、認証開始 endpoint に既存 login を要求しない。`/healthz` は非機密の process liveness のみで、外部から無認証到達できる保証ではない。

accounts は Google sign-in と public-client OAuth、header は値を除去・上書きする trusted proxy と直接到達防止を使う。[共通 OAuth](../shared/oauth.md)、[Databricks identity](databricks.md)、[Database](database-and-identity.md)、[管理者](sharing-and-administration.md#server-管理者)、[timeout](../shared/ai-timeouts.md) を各境界の判断とする。

## 配布と拡張

`apps/server` は実行アプリ兼 `@dahlia-ai/server` package。macOS と独立した SemVer / `server-v<version>` tag で配布し、root export は Worker-safe、Node API は `/node` subpath に限定する。

backend extension は Better Auth plugin、認証前 route、認証済み API、session capability、Gateway 転送前 hook を追加できる。client extension はブランド、navigation、capability で保護した未予約 Dashboard route / React page を追加できるが、組み込み route は上書きしない。

Server migration を常に先、extension migration を後に合成し、各 ledger ID と SQLite の実行 filename を明示する。公開済み migration は不変。consumer は exact version、開発は `pnpm link`、公開物確認は `pnpm pack` を使う。extension contract の破壊的変更は major version を必要とする。

## 理由と制約

fork や機能別 provider adapter の重複を避ける代わりに、明示した hook / migration / version の互換性を管理する。Server は extension 固有の dependency、schema、設定、運用を所有しない。secret、request content、録音、Desktop DB を新しい共有 extension contract に含めない。

初期 Gateway は Personal workspace と AI 中継だけに限定した。後に採択された [Artifact](artifacts.md)、[canonical sync](../shared/sync.md)、[共有](sharing-and-administration.md) は別の保存・認可境界であり、中継内容の永続保存禁止を解除しない。初期の root pnpm workspace と管理者 email table は、アプリ単位の依存管理と共通 Auth role に置き換わった。
