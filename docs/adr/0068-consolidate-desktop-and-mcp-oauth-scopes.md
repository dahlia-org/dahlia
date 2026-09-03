# ADR-0068: Consolidate Desktop and MCP OAuth scopes

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0029, ADR-0045, ADR-0049, ADR-0051, ADR-0056, ADR-0067

## Context

Dahlia Desktop is the only client of the main Server API. Maintaining separate model, artifact, and sync capability scopes added reauthorization and deployment-specific compatibility paths without isolating independent clients.

## Decision

- Dahlia Desktop requests `all-apis` for the main API resource. Models, Responses, artifacts, transactions, deltas, events, and synchronized content routes require that scope for bearer-token access.
- Databricks Apps deployments use the same `all-apis` Desktop authorization request. DAB `user_api_scopes` remain `ai-gateway` and `files` because they govern the forwarded OBO token, not Dahlia's API capability.
- The MCP resource exposes only `mcp` and `mcp:read`. `mcp` grants every MCP operation; `mcp:read` grants only read tools and authenticated screenshot resources.
- `openid`, `profile`, `email`, and `offline_access` remain OAuth/OIDC protocol scopes rather than Dahlia API capabilities.
- Header authentication remains a trusted-proxy boundary. Its synthesized MCP identity receives `mcp`; main API authorization continues to rely on the verified proxy identity.

## Consequences

Desktop authorization and capability checks use one stable API scope. MCP clients can still request read-only access without losing a simple full-access scope, while the former `api.model.*`, `api.artifact.*`, and `api.sync.*` scopes are no longer accepted or advertised.
