# Deploy Dahlia Server

| Target | Authentication metadata | Gateway configuration | Guide |
| --- | --- | --- | --- |
| Cloudflare Workers | accounts/header + D1, Hyperdrive, or PostgreSQL | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | [Cloudflare](cloudflare/README.md) |
| Databricks Apps | header + Lakebase | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | [Databricks](databricks/README.md) |
| Node container | accounts/header + SQLite, PostgreSQL, or Lakebase | `OPENAI_API_KEY` + optional `OPENAI_BASE_URL` | [Node](../README.md#local-node-deployment) |

Every target exposes the same endpoints. Administrators choose the public Model Aliases:

- `GET /api/v1/models`
- `POST /api/v1/responses`

Provider credentials remain independent runtime configuration. Better Auth, public Model Aliases, administrators, and future meeting sync use the selected application database; request content and provider secrets do not.
