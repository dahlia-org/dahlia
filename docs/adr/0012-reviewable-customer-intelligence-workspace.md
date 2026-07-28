# ADR 0012: Simple customer-intelligence MCP writes

- Status: Accepted
- Date: 2026-07-27
- Amends: [ADR 0011](0011-vault-scoped-customer-intelligence.md)

## Context

Enterprise customer work spans many departments, contacts, projects, and recurring conversations. Calendar ingestion
provides reliable participation facts, while summaries and transcripts provide organization, topic, and insight claims.
In practice, a large mutation DSL plus proposal/import staging made ordinary edits harder for an agent to compose,
inspect, retry, and recover.

The research recommendation rejects a single unbounded graph canvas, graph database, free-position persistence,
sentiment, and synthetic progress scores. It favors typed entities, source evidence, and bounded task-specific views.

## Decision

Dahlia exposes small, composable MCP tools. Canonical records use `query/get/create/update/delete`; relationships use
`query/set/remove`. Each write transaction changes exactly one record or one relationship.

- `update_*` requires the current entity revision and leaves omitted fields unchanged.
- `set_*` creates a missing relationship or updates its metadata. `remove_*` removes only the relationship.
- Repeating an already-satisfied `set` or `remove` succeeds with `changed: false`.
- `resolve_contact` remains a named domain operation because it merges two Contacts and moves typed references.
- `delete_*` requires the current revision and is not idempotent. A missing record returns `not_found`.
- Organizations can be deleted only as empty leaves. Contacts can be deleted only after every Membership, Meeting
  participant, Project, Topic, and Insight reference is removed. Blocking references return
  `resource_in_use` with counts.
- Topic and Insight deletion removes only the owner's typed references; referenced canonical records remain.
- A failed call does not roll back prior calls. The agent continues independent work, then re-fetches and retries only
  the failed record.
- Proposal queues, mutation DSLs, imports, batches, caller-local dependency keys, and persisted idempotency staging are
  not part of the contract.
- Codex app-server `auto_review` evaluates each write tool. Dahlia adds no separate permission-mode switch.
- `meeting_participants` has no mutation tool, structurally preventing AI-generated calendar participation.
- Project and Meeting participant deletion are not exposed by customer-intelligence MCP tools.
- Insight acceptance is a Bool (`isAccepted`); AI-created Insights default to false.
- Topic status and progress are not stored. Last discussion, Meeting count, and related-organization count are derived
  from typed reference history.
- Glossary is not part of the current product. A standalone local term store added schema and MCP surface without
  improving transcription or AI context, so it was removed directly from the unreleased v25/v26 schema before release.
  Terminology can be reconsidered later as an input to transcription correction or AI context rather than as an
  isolated record.

The organization canvas is a bounded hierarchy viewer for one customer root. It uses canonical parent relationships,
loads children on expansion, lays nodes out automatically, and never persists coordinates. Contacts appear in the
inspector rather than as graph nodes. Topic focus dims unrelated hierarchy nodes without drawing cross-links. This is
not the global graph canvas rejected by the research.

## Consequences

Agents can build large updates by composing predictable schemas and can recover from an individual conflict without
replaying a monolithic payload. The tradeoff is that a user request is not globally atomic: earlier successful calls
remain visible when a later call fails.

The schema keeps nullable Contact email, entity revisions, Topic references, and Boolean Insight acceptance.
`v25_customerIntelligence` and `v27_customerIntelligenceWorkspace` contain the unreleased schema directly and never
create Glossary, proposal, import, or development-only idempotency tables. The additive
`v28_customerIntelligenceTopicReferenceTimestamp` migration makes reference cleanup update the Topic timestamp as well
as its revision. `v29_customerIntelligenceDirectCRUD` reconciles QA databases opened against an earlier pre-release
schema: it maps string Insight review state to Boolean acceptance, supplies revision values, removes retired staging
tables, and restores the validation and cleanup triggers current at the time of this decision. The MCP contract
required v29 at that point so it never treated a partially upgraded QA database as current. The
[workspace documentation](../customer-intelligence-workspace.md#mcp) records the current schema requirement.

App and MCP database queues wait up to five seconds for a writer. A single failed call never partially commits.
Calendar facts retain a stronger provenance boundary than AI-derived organization knowledge.

## References

- [MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Notion MCP supported tools](https://developers.notion.com/guides/mcp/mcp-supported-tools)
- [Linear MCP](https://linear.app/docs/mcp)
- [Salesforce Hosted MCP](https://developer.salesforce.com/docs/platform/hosted-mcp-servers/guide/products-supporting-mcp.html)
- [Codex app-server MCP approvals](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#mcp-server-elicitations)
