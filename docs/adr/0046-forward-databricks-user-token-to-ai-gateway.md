# ADR-0046: Databricks user token を AI Gateway へ転送する

- Status: Accepted
- Date: 2026-08-29
- Amends: ADR-0029, ADR-0044

## Context

Databricks Apps proxy は認証済み request に `X-Forwarded-Access-Token` を付与する。Dahlia Server が App service principal の OAuth token を別途取得すると、AI Gateway の呼び出し主体が利用者ではなく App になり、proxy が既に渡した user credential と二重の認証経路を持つ。

## Decision

- `DAHLIA_AI_BACKEND=databricks` は `DATABRICKS_HOST` から `https://<workspace-host>/ai-gateway/mlflow/v1/responses` を構成する。
- `POST /api/v1/responses` に Apps proxy が付与した `X-Forwarded-Access-Token` を upstream の `Authorization: Bearer ...` として使う。
- 管理画面のモデル発見は同じ user token で Unity Catalog Model Services API の `system.ai` schema を全ページ取得する。App は Responses 用の `ai-gateway` に加えて、発見用の `catalog.catalogs:read` と `catalog.schemas:read` user API scopes を要求する。
- forwarded token がない request は upstream を呼ばず `401 databricks_access_token_required` を返す。
- token は request の間だけ扱い、保存、log、cache、response、upstream の `X-Forwarded-Access-Token` header には含めない。
- App service principal の client credential token 取得は行わない。Lakebase の credential refresh は database adapter の独立した責務として維持する。
- 公開 Codex contract は引き続き `/api/v1/models` と `/api/v1/responses` とし、Databricks 固有 path は upstream adapter 内に閉じ込める。

## Consequences

- AI Gateway の認可と監査は request を開始した Databricks user の token に対応する。
- 管理画面には user が Unity Catalog で参照できる `system.ai` model service だけが表示される。
- Apps proxy を通らない Databricks backend request は Responses を実行できない。
- `DATABRICKS_CLIENT_SECRET` を AI provider 設定として保持せず、OAuth token cache と更新処理も不要になる。
