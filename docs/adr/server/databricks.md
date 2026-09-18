# Databricks 配置と upstream identity

対象: Server / Databricks Apps。採択: 2026-08-29〜08-31、モデル一覧改訂: 2026-09-05、SP fallback 範囲改訂: 2026-09-19。配置手順は [Deployment guide](../../../deploy/databricks/README.md)。

## 配置

`deploy/databricks` の DAB が App と Lakebase Autoscaling project を配置し、`apps/server` だけを同期する。App は `databricks_postgres` へ `CAN_CONNECT_AND_CREATE` で接続する。auth / app と migration ledger は [Database](database-and-identity.md#schema-と-migration) に従う。

authentication、canonical origin、AI backend は独立に選ぶ。Node origin は HTTP/1.1、外部 HTTP/2・HTTP/3 は edge proxy が終端する。trusted proxy はすべての利用する forwarded header を client 値から除去・上書きし、直接 Server に到達させない。

managed Volume resource key は `dahlia_storage`、既定名は `storage`。Unity Catalog の既定は catalog `dahlia` / schema `server` とし、環境切替は実行者の catalog variable で行う。既存の開発 DB / Volume の自動移行はこの判断に含めない。

## Upstream identity

| 操作 | Credential / 意図 |
| --- | --- |
| Responses | 当該 request の `X-Forwarded-Access-Token` を優先し、ない場合は App service principal の短期 token を使用 |
| configured model list | `DAHLIA_FOUNDATION_MODELS`。upstream request なし |
| Volume access | App service principal の既存 storage 権限。利用者の forwarded token を使わない |

`DAHLIA_AI_BACKEND=databricks` は `DATABRICKS_HOST` の `/ai-gateway/mlflow/v1/responses` を使う。forwarded token を優先し、ない場合は設定済み App service principal credential で短期 token を取得する。この選択は Server の実行環境に依存しない。forwarded token は request 外に保持せず、元 header 名のまま転送、保存、log、client 返却をしない。

モデル一覧は `DAHLIA_FOUNDATION_MODELS` から読み、`system.ai.*` の完全修飾名をそのまま公開・転送する。App service principal は forwarded token がない interactive Responses、background summary、embedding、image analysis、Volume access に使用し、credential と upstream body は保存・log しない。

## 経緯と制約

初期は AI 呼出を App 主体にし、その後 Responses で OBO を優先するよう変更した。2026-09-19 に、実行環境や呼出元によらず `DAHLIA_AI_BACKEND=databricks` の全 Responses で、OBO token がない場合の App service principal fallback を許可した。upstream の認可・監査主体は OBO 使用時は利用者、fallback 時は App service principal となる。request tag の認証済み user ID は相関情報であり、OBO の代替ではない。モデル一覧は upstream discovery を行わないため、どちらの token の可用性にも依存しない。

発見用の `catalog.catalogs:read` / `catalog.schemas:read` user scope は廃止した。DAB の OBO scope と Desktop の `all-apis` は [共通 OAuth](../shared/oauth.md#scope) の別境界。provider secret を bundle や利用者へ配布せず、App runtime から取得する。

2026-09-05 に DB の Model Alias 管理を廃止し、2026-09-16 に backend discovery と DAB の暫定登録処理を廃止した。公開名・予約モデルは [Backend モデル契約](gateway.md#backend-モデル契約) に従う。
