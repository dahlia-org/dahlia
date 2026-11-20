# Databricks 配置と upstream identity

対象: Server / Databricks Apps。採択: 2026-08-29〜08-31。SP fallback 範囲改訂: 2026-09-19。モデル一覧改訂: 2026-10-03。配置手順は [Deployment guide](../../../deploy/databricks/README.md)。

## 配置

`deploy/databricks` の DAB が App と Lakebase Autoscaling project を配置し、`apps/server` だけを同期する。App は `databricks_postgres` へ `CAN_CONNECT_AND_CREATE` で接続する。auth / app と migration ledger は [Database](database-and-identity.md#schema-と-migration) に従う。

authentication、canonical origin、AI backend は独立に選ぶ。Node origin は HTTP/1.1 とし、外部の HTTP/2・HTTP/3 は edge proxy が終端する。trusted proxy はすべての利用する forwarded header を client 値から除去・上書きし、直接 Server に到達させない。

managed Volume の resource key は `dahlia_storage`、既定名は `storage`。Unity Catalog の既定は catalog `dahlia` / schema `server` とし、環境の切替は実行者の catalog variable で行う。既存の開発 DB / Volume の自動移行はこの判断に含めない。

## Upstream identity

| 操作 | Credential / 意図 |
| --- | --- |
| Responses（`/ai-gateway/codex/v1/responses`） | 当該 request の `X-Forwarded-Access-Token` を優先し、ない場合は App service principal の短期 token |
| モデル一覧（`/ai-gateway/codex/v1/models`） | 同じく `X-Forwarded-Access-Token` を優先し、ない場合は App service principal の短期 token。ローカル JSON への fallback はしない |
| background Chat Completions / Embeddings（`/ai-gateway/mlflow/v1`） | App service principal |
| Volume access | App service principal の storage 権限。利用者の forwarded token を使わない |

`DAHLIA_AI_BACKEND=databricks` は `DATABRICKS_HOST` の上記 Gateway path を使う。forwarded token は request 外に保持せず、元の header 名のまま転送、保存、log、client 返却をしない。この選択は Server の実行環境に依存しない。

App service principal は、forwarded token がない interactive Responses、background summary、embedding、image analysis、Volume access に使う。credential と upstream body は保存・log しない。upstream の認可・監査主体は OBO 使用時は利用者、fallback 時は App service principal となる。request tag の認証済み user ID は相関情報であり、OBO の代替ではない。

発見用の `catalog.catalogs:read` / `catalog.schemas:read` user scope は使わない。DAB の OBO scope と Desktop の `all-apis` は [共通 OAuth](../shared/oauth.md#scope) の別境界である。provider secret を bundle や利用者へ配布せず、App runtime から取得する。

公開するモデルの一覧は Databricks のプラットフォームが管理する（[プラットフォームによるモデル公開管理](#プラットフォームによるモデル公開管理)）。モデル一覧は upstream の呼出しを伴うため、どちらの token の可用性にも依存する。

## プラットフォームによるモデル公開管理

Databricks では、表示モデルの公開・順序・metadata・client version 判定・推論のモデル認可をプラットフォームに委ねる。`DAHLIA_FOUNDATION_MODELS` による一覧は使わない。Server はモデル一覧にローカルでモデルを追加・削除しない。

Web チャットは `/api/v1/models` を使い、`capabilities.ai.bundledModels` が `codex` の場合だけ承認済み GPT の表示・推論 metadata をクライアント側で補完する。`/api/v1/chat/models` は持たない。同一 slug は上流の定義を優先し、非表示・API 不可・不正な推論設定であれば補完しない。Server のチャット入力検証は同じ合成処理を使うが、推論の最終認可は上流に委ねる。

`resources/codex/source.json` に取得元 URL・version・原本の SHA-256・採用モデル一覧をまとめ、GPT 6 系の表示・推論 metadata だけを `resources/codex/models.json` に生成する。原本は Desktop の固定版 Codex と同じ tag から生成時にメモリ上で取得・検証し、ファイルには保存しない。`pnpm codex-models:generate` は取得・検証・絞り込み・生成をまとめて行う。通常のビルド・実行時には取得しない。`pnpm codex-models:check` はフィルタ済み JSON の採用モデルと生成形式をオフラインで確認する。Gateway の返却 catalog にローカル GPT を追加せず、discovery 失敗時にも補完を使わない。

2026-10-03 の実測: 上流の Models API は Kimi／GLM の定義を返す一方、一覧にない native ID `gpt-6.1-sol` への Responses は成功した。
