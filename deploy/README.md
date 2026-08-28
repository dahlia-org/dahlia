# Deploy Dahlia Server

| Target | Authentication metadata | Gateway configuration | Guide |
| --- | --- | --- | --- |
| Cloudflare Workers | accounts/header + D1, Hyperdrive, or PostgreSQL | `DAHLIA_AI_BACKEND=cloudflare` + API token | [Cloudflare](cloudflare/README.md) |
| Databricks Apps | header + Lakebase | `DAHLIA_AI_BACKEND=databricks` + App OAuth | [Databricks](databricks/README.md) |
| Node container | accounts/header + SQLite, PostgreSQL, or Lakebase | `DAHLIA_AI_BACKEND=openai` + API key | [Node](../apps/server/README.md#local-node-deployment) |

Every target exposes the same endpoints. Administrators choose the public Model Aliases:

- `GET /api/v1/models`
- `POST /api/v1/responses`

Provider credentials remain independent runtime configuration. Better Auth, public Model Aliases, administrators, and future meeting sync use the selected application database; request content and provider secrets do not.
