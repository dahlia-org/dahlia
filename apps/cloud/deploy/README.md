# Deploy Dahlia Cloud

| Target | Authentication metadata | Gateway configuration | Guide |
| --- | --- | --- | --- |
| Cloudflare Workers | `DAHLIA_RUNTIME=cloudflare`: accounts + D1 | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | [Cloudflare](cloudflare/README.md) |
| Databricks Apps | `DAHLIA_RUNTIME=databricks`: header + PostgreSQL/Lakebase | `OPENAI_API_KEY` + `OPENAI_BASE_URL` | [Databricks](databricks/README.md) |
| Node container | `DAHLIA_RUNTIME=custom`: accounts/header + SQLite/PostgreSQL | `OPENAI_API_KEY` + optional `OPENAI_BASE_URL` | [Node](../README.md#local-node-deployment) |

Every target exposes the same endpoints. Administrators choose the public Model Aliases:

- `GET /api/v1/models`
- `POST /api/v1/responses`

Provider credentials remain runtime configuration. Public Model Aliases and administrator emails are stored in the application database; recordings, transcripts, request content, and provider secrets are not.
