# Databricks 配置と upstream identity

対象: Server / Databricks Apps。採択: 2026-08-29〜08-31。配置手順は [Deployment guide](../../../deploy/databricks/README.md)。

## 配置

`deploy/databricks` の DAB が App と Lakebase Autoscaling project を配置し、`apps/server` だけを同期する。App は `databricks_postgres` へ `CAN_CONNECT_AND_CREATE` で接続する。Auth / core / content と migration ledger は [Database](database-and-identity.md#schema-と-migration) に従う。

authentication、canonical origin、AI backend は独立に選ぶ。Node origin は HTTP/1.1、外部 HTTP/2・HTTP/3 は edge proxy が終端する。trusted proxy はすべての利用する forwarded header を client 値から除去・上書きし、直接 Server に到達させない。

managed Volume resource key は `dahlia_storage`、既定名は `storage`。Unity Catalog の既定は catalog `dahlia` / schema `server` とし、環境切替は実行者の catalog variable で行う。既存の開発 DB / Volume の自動移行はこの判断に含めない。

## Upstream identity

| 操作 | Credential / 意図 |
| --- | --- |
| Responses | 当該 request の `X-Forwarded-Access-Token` を upstream Bearer に変換。利用者の認可と監査を維持 |
| system model discovery | runtime の `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` による短期 App service principal token |
| Volume access | App service principal の既存 storage 権限。利用者の forwarded token を使わない |

`DAHLIA_AI_BACKEND=databricks` は `DATABRICKS_HOST` の `/ai-gateway/mlflow/v1/responses` を使う。forwarded token がなければ Responses を upstream 呼出前に拒否し、App token へ fallback しない。token は request 外に保持せず、元 header 名のまま転送、保存、log、client 返却をしない。

モデル発見は `system.ai` を全ページ取得し、Volume と共通の `DatabricksTokenProvider` で token の期限前更新と同時要求を集約する。Databricks AI backend は storage 選択にかかわらず App credential を必要とする。credential と upstream body は保存・log しない。

## 経緯と制約

初期は AI 呼出を App 主体にし、その後 Responses を OBO に変更した。モデル発見まで OBO にすると scope / consent 更新後も403となったため、発見だけを App 主体へ分離した。モデル一覧と Responses の監査主体は一致しない。

発見用の `catalog.catalogs:read` / `catalog.schemas:read` user scope は廃止した。DAB の OBO scope と Desktop の `all-apis` は [共通 OAuth](../shared/oauth.md#scope) の別境界。provider secret を bundle や利用者へ配布せず、App runtime から取得する。
