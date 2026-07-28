# ADR 0014: Domain-driven Organization merge

- Status: Accepted
- Date: 2026-07-28
- Amends: [ADR 0011](0011-vault-scoped-customer-intelligence.md), [ADR 0012](0012-reviewable-customer-intelligence-workspace.md)

## Context

Calendar ingestion initially creates one root Organization for each non-public email domain. Some companies use multiple
domains, such as `example.com` and `example.co.jp`, so independent observations can split one real company into multiple
Organizations. The schema already allows one Organization to own multiple domains, but the UI did not expose that
relationship and the existing add operation rejected a domain owned by another Organization.

Moving only the domain would correct future classification while leaving existing Memberships, departments, Projects,
Topics, and Insights under the obsolete Organization. Users need one canonical customer scope without losing those
relationships.

## Decision

The Organization inspector exposes the domains of a selected root Organization and an explicit add-domain operation.

- An unassigned canonical domain is attached to the selected Organization.
- A domain already owned by the selected Organization is a no-op.
- A domain owned by another root Organization produces a review step, then merges that source into the selected target
  in one SQLite transaction.
- The merge moves all source domains with their observation timestamps, direct Memberships, the descendant hierarchy, and
  direct Project, Topic, and Insight references before deleting the source.
- The target keeps its name, hierarchy, and primary domain. If it has no primary domain, the source primary is retained.
  When an identical Membership or typed reference exists on both sides, target metadata wins; non-conflicting source
  relationships are preserved.
- The initiating canonical domain is part of the reviewed merge identity. Preview and commit both verify that the source
  still owns it, and the add sheet remains bound to the target Organization and Vault that opened it.
- Both Organization revisions and the reviewed impact counts must still match. A conflict rolls back the complete
  transaction and requires a fresh review.

Only root Organizations can participate. This keeps the operation aligned with domain-created customer identities and
avoids introducing arbitrary hierarchy-collapse semantics. The operation is available in the app UI only; the MCP
contract remains unchanged.

## Consequences

- Multiple domains resolve to one Organization for future ingestion, and historical customer intelligence remains in
  the same canonical scope.
- The existing schema needs no migration.
- The source Organization name is intentionally discarded. The review dialog communicates that the source is deleted.
- Domain removal, primary-domain editing, and a general-purpose Organization merge remain separate work.
