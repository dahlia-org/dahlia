# ADR-0049: artifact 操作を remote MCP で公開する

- Status: Accepted
- Date: 2026-08-30
- Amends: ADR-0029, ADR-0044, ADR-0045, ADR-0048

## Context

Artifact REST API は owner-scoped の作成、置換、公開範囲変更、削除を提供するが、remote agent が同じ操作を MCP tool として発見・実行する契約はない。Internet-facing MCP は OAuth protected-resource discovery と client registration の取り扱いを明示する必要がある。一方 Databricks Apps は request が Server に届く前に Apps proxy が利用者を OAuth 認証し、検証済み identity header を付与する。

## Decision

- `/mcp` に MCP 2026-07-28 の stateless、modern-only endpoint を置く。`create_artifact`、`update_artifact_content`、`update_artifact_visibility`、`delete_artifact` を提供し、list、read、history は追加せず、既存の Artifact service と owner authorization を再利用する。
- tool input は UTF-8 または canonical RFC 4648 base64 とし、decoded bytes は 8 MiB、MCP HTTP request は 12 MiB を上限にする。大容量 streaming は REST API に残す。作成は private、置換は既存 content type と owner を維持し、結果は正準 Dahlia URL と resource link だけを返す。
- accounts mode は resource `${baseUrl}/mcp` に DPoP-bound access token を必須とし、scope `api.artifact.write`、path-aware RFC 9728 metadata、issuer、audience、expiry、subject、workspace claim、および DPoP sender constraint を検証する。Node authorization server は MCP 2026-07-28 profile の CIMD を secure pinned fetch で提供し、RFC 7591 DCR は無効のままとする。
- Databricks Apps の header mode は Apps proxy の OAuth 認証済み identity を owner として使い、Server 内の OAuth challenge を重ねない。artifact storage は App service principal の既存 Volume permission を使い、`X-Forwarded-Access-Token` は使わない。したがって DAB の user API scope は増やさない。
- browser-origin request は configured origin と一致させる。Origin を送らない non-browser MCP client は許可する。content、tool input/output、token、storage URL は log に残さない。

## Consequences

- remote agent は Artifact REST contract を重複実装せず、同じ owner/private/public semantics で artifact を操作できる。
- Databricks Apps は platform proxy の authentication boundary と既存 storage permission を保つ。
- Cloudflare accounts runtime は secure CIMD transport を提供していないため CIMD を advertise せず、remote MCP client を onboarding しない。accounts mode で利用するには、runtime が DNS resolve-once、public-address rejection、connection pinning、redirect refusal を満たす transport を追加する必要がある。
