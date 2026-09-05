# ADR-0069: AI backend をモデル一覧と Responses の互換境界にする

- Status: Accepted
- Date: 2026-09-05
- Amends: ADR-0029, ADR-0031, ADR-0050

## Decision

`AIGatewayBackend` は `listModels(request)` と `responses(body, context)` を持つ。共通の `RequestBody` は Responses API 形式、`RequestContext` は認証済み userId、headers、signal と Server が解決した任意の upstreamModel を持つ。backend は利用者情報を保持せず、上流ヘッダーを明示的に構築する。型と backend 実装は Worker-safe な package root で公開する。

モデル一覧の正本を backend へ移し、`/admin/models` と管理 API を廃止する。既存 Model Alias のデータ・store 型・migration は変更しない。Databricks は必須の `DATABRICKS_MODEL_SCHEMA` 配下を App service principal で取得し、短い名前を公開する。通常の Responses は backend 内でスキーマを補完し、利用者の OBO token で転送する。認証済み userId は Databricks request tags の user_id に設定する。OpenAI と Cloudflare の一覧は当面 gpt-5.6-luna の mock とする。

`CODEX_AUTO_REVIEW_MODEL` は backend の機能に依存しない Server 共通機能として維持する。設定時は予約 ID codex-auto-review の一覧と実行先を上書きし、環境変数の上流 ID を無加工で転送する。未設定時は予約 ID を無効化し、backend に同名モデルがあっても利用させない。

Databricks DAB は catalog.ai schema を管理し、postdeploy が暫定措置として gpt-5-6-luna Model Service を直接登録する。重複確認・再試行は行わず、既存時は作成エラーを返す。権限付与は operator に任せる。

## Consequences

モデル公開のために Dahlia DB と Databricks の両方を管理する必要がなくなる。一覧の可用性は backend に依存する。旧 Alias 名を利用するクライアントは新しい一覧の ID を選び直す必要がある。予約モデルの環境変数上書きは全 backend で維持される。

録音・文字起こし・Server canonical data の契約と、Responses の非永続化・streaming 境界は変更しない。
