# Deploy Dahlia Server on Databricks Apps

This target uses the checked-in `DAHLIA_RUNTIME=databricks` preset: Databricks Apps header identity and PostgreSQL/Lakebase. The upstream uses the same OpenAI-compatible contract as every runtime. The Apps proxy authenticates browser and U2M requests before they reach Dahlia Server, so no Better Auth session is created.

```text
browser / Dahlia Codex with U2M token
        │
        ▼
Databricks Apps proxy
        │ X-Forwarded-Email
        ▼
Dahlia Server App ─┬─ OPENAI_API_KEY ── OpenAI-compatible Responses API
                  └─ app service principal ── Lakebase PostgreSQL
```

Databricks requires `app.yaml` at the deployment source root. Deploy the repository root so the pnpm workspace and lockfile remain available.

## Prerequisites

- A Databricks workspace with Databricks Apps enabled.
- Permission to create and deploy an app.
- The Databricks CLI installed and authenticated.
- Node.js 22.13 or newer, Corepack, and pnpm for local validation.

## 1. Create the app and attach Lakebase

Create a Databricks App and add a [Lakebase Autoscaling database resource](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/lakebase). Databricks injects `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER` for the first database resource. Keep `DAHLIA_RUNTIME=databricks` in the checked-in `app.yaml`; it fixes authentication to `header` and the database backend to PostgreSQL. `DAHLIA_AUTH_HEADER` defaults to `X-Forwarded-Email`.

Header authentication itself is sessionless. Lakebase stores Model Aliases and platform administrators, so model listing, Responses routing, and administrator checks query it without changing the identity boundary. Dahlia uses the injected `PG*` connection values and rotates Lakebase OAuth database credentials through the app service principal.

Add the public origin:

```yaml
  - name: DAHLIA_BASE_URL
    value: https://<app-host>
```

Ensure the database resource key is `postgres`. The checked-in `app.yaml` maps that resource to `ENDPOINT_NAME`; Databricks supplies the remaining `PGHOST`, `PGDATABASE`, `PGPORT`, `PGSSLMODE`, and `PGUSER` variables.

## 2. Configure the upstream provider and administrator

Databricks Apps injects `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, and `DATABRICKS_CLIENT_SECRET`; Dahlia uses them only for Lakebase credential generation. Configure the model endpoint separately.

Add its API key or token as a Databricks App Secret resource with the resource key `openai_api_key`. Keep the credential in its secret scope; do not put it directly in `app.yaml`. Then reference the resource:

```yaml
  - name: OPENAI_API_KEY
    valueFrom: openai_api_key
  - name: OPENAI_BASE_URL
    value: https://<workspace-host>/ai-gateway/openai/v1
```

Optionally bootstrap the management UI with:

```yaml
  - name: DAHLIA_ADMIN_EMAIL
    value: <administrator-email>
```

Dahlia never stores or forwards `X-Forwarded-Access-Token`. The model credential is sent only as `Authorization: Bearer <OPENAI_API_KEY>` to `OPENAI_BASE_URL`; the app service-principal client secret is never sent to that endpoint.

Grant inference permissions to the exact user or service principal that owns `OPENAI_API_KEY`. Rotate the secret before it expires and update the App Secret resource. A valid token does not imply inference permission; verify it with the Responses smoke test below. This deployment uses the OpenAI-compatible endpoint above and does not configure a model-provider-service header.

After deployment, sign in as the administrator and create each public alias and upstream model under `/admin/models`.

## 3. Validate and build

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm check
pnpm build
```

Databricks runs the root `build` script during deployment. The startup command then applies the PostgreSQL migration under an advisory lock and starts the Server package. Header authentication does not create sessions, but the shared schema contains Gateway administration tables.

## 4. Upload and deploy

```bash
databricks sync . /Workspace/Users/<you>/dahlia-server
databricks apps deploy <app-name> \
  --source-code-path /Workspace/Users/<you>/dahlia-server
```

Alternatively, deploy from Git with the repository root as the source directory.

## 5. Smoke test

```bash
TOKEN="$(databricks auth token --output json | jq -r .access_token)"

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/session

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  https://<app-host>/api/v1/models
```

Create an alias in `/admin/models`, then complete a real `POST /api/v1/responses` request with that alias and `stream: true`. Confirm SSE events arrive incrementally through the Apps proxy.

## Path and security requirements

- Databricks Apps identity applies to `/api/**`; authenticated Dahlia endpoints therefore remain under `/api`.
- Trust `X-Forwarded-Email` only behind the Databricks Apps proxy. Dahlia ignores `X-Forwarded-User`.
- For another identity-aware proxy, use `DAHLIA_RUNTIME=custom`, set `DAHLIA_AUTH_PROVIDER=header` and `DAHLIA_AUTH_HEADER` to its verified email header, and optionally restrict `DAHLIA_TRUSTED_PROXY_CIDRS`.
- `/healthz` is process liveness only. Anonymous external access is not guaranteed.
- Provider credentials live in Databricks-managed app secrets and environment variables; Dahlia Server does not persist them.
