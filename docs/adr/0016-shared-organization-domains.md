# ADR 0016: Organization domains can be shared

- Status: Accepted
- Date: 2026-07-31
- Amends: [ADR 0011](0011-vault-scoped-customer-intelligence.md),
  [ADR 0014](0014-domain-driven-organization-merge.md)

## Context

Independent top-level companies can use the same email domain. Treating `(vaultId, domainName)` as unique forced those
companies into one Organization and made calendar ingestion assign Contacts to a company without enough evidence.
Domain-driven merge remains useful when two records represent one company, but it must not be the only way to add an
already-observed domain.

## Decision

- `organization_domains` uses `(vaultId, domainName, organizationId)` as its primary key. The v33 migration rebuilds the
  table and copies existing rows without transforming them.
- Only root Organizations can receive domains through supported Repository and MCP writes. One Organization still has
  exactly one primary domain whenever it has domains.
- Calendar ingestion creates an Organization only for the first observation of a non-public domain. Later observations
  update `firstObservedAt` and `lastObservedAt` on every Organization sharing that domain.
- Automatic Contact membership is controlled by a setting that defaults to enabled for compatibility. It is always
  suppressed when a domain has multiple Organization owners. Contact creation, Meeting participation, and first-domain
  Organization creation continue when the setting is disabled.
- When one other root owns a domain, the UI offers either a non-destructive shared assignment or the existing destructive
  Organization merge. When multiple roots already share it, the UI adds another shared assignment without offering merge.
- Merge coalesces a domain already present on the target by taking the earliest first observation and latest last
  observation while preserving the established primary-domain rule.
- Write-enabled MCP sessions expose `set_organization_domain` and `remove_organization_domain`. Agents use explicit
  Contact membership tools and Meeting evidence to classify Contacts on shared domains. The common customer-intelligence
  schema gate advances to `v33_sharedOrganizationDomains`; this is an intentional compatibility change.

## Consequences

Shared corporate email infrastructure no longer requires a false Organization merge. Automatic ingestion remains useful
for unambiguous domains, while ambiguous membership requires user or evidence-based agent action. Existing database rows
and observation timestamps retain their meaning.
