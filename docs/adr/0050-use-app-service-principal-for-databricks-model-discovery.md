# ADR-0050: Databricks のモデル発見に App service principal を使う

- Status: Accepted
- Date: 2026-08-31
- Amends: ADR-0044, ADR-0046

## Context

Databricks Apps の OBO token では Unity Catalog Model Services API のモデル一覧取得が `403` になり、user API scopes と consent を更新しても管理画面にモデルを表示できなかった。一方、Responses は利用者単位の認可と監査を維持する必要がある。

## Decision

- `GET /api/admin/models` の system model discovery は、runtime が注入する `DATABRICKS_CLIENT_ID` と `DATABRICKS_CLIENT_SECRET` から取得した短期 App service principal token を使う。
- token の取得、期限前更新、同時 request の集約は Volume access と同じ `DatabricksTokenProvider` を再利用する。token、credential、upstream response body は保存または log しない。
- `POST /api/v1/responses` は引き続き request の `X-Forwarded-Access-Token` を upstream Bearer credential として使う。モデル発見は forwarded token を使わない。
- Databricks AI backend は storage backend にかかわらず App service principal credentials を必要とする。
- モデル発見用だった `catalog.catalogs:read` と `catalog.schemas:read` user API scopes は App から除去する。

## Consequences

- 管理者の user token の scope や consent に依存せず、App に許可された system model を管理画面へ表示できる。
- モデル一覧 API の監査主体は App service principal、Responses の監査主体は request を開始した利用者になる。
- Databricks Apps 以外で Databricks AI backend を使う operator は、workspace host と service principal credentials を設定する必要がある。
