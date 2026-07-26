# ADR 0012: Reviewable customer-intelligence workspace

- Status: Accepted
- Date: 2026-07-27
- Amends: [ADR 0011](0011-vault-scoped-customer-intelligence.md)

## Context

Enterprise customer work spans many departments, contacts, projects, and recurring conversations. Calendar ingestion
provides reliable participation facts, while summaries and transcripts provide less certain organization and topic
claims. A useful overview must connect both without allowing an AI interpretation to silently become canonical data.

The research recommendation rejects a single unbounded graph canvas, graph database, free-position persistence,
sentiment, and synthetic progress scores. It favors typed entities, source evidence, and bounded task-specific views.

## Decision

Dahlia stores conversation Topics and reviewable customer-intelligence proposals separately from canonical
Organizations, Contacts, memberships, Projects, and Meetings.

- Analysis creates small proposals. It does not mutate canonical customer intelligence.
- A proposal is applied only from the review UI or after an explicit user instruction to the write-enabled MCP session.
- Proposal decoding and dependency-cycle checks happen before a write transaction. Status, revision, dependencies,
  target existence, Vault, and expected field values are checked again in the same transaction that applies the batch.
- Entity revisions detect stale direct UI edits. Proposals require an expectation for every changed canonical field,
  so an unrelated revision change does not invalidate an otherwise applicable proposal.
- `meeting_participants` has no proposal operation. This schema-level omission prevents an AI from manufacturing
  calendar participation facts.
- Resolving a provisional Contact rewrites evidence to the surviving Contact and marks unapplied payload references
  `stale` with `contactResolved`. UI deletion similarly uses `contactDeleted`, `organizationDeleted`, or `topicDeleted`.
- Topic status and progress are not stored. Last discussion, Meeting count, and related-organization count are derived
  from typed reference history.

The organization canvas is a bounded hierarchy viewer for one customer root. It uses canonical parent relationships,
loads children on expansion, lays nodes out automatically, and never persists coordinates. Contacts appear in the
inspector rather than as graph nodes. Topic focus dims unrelated hierarchy nodes without drawing cross-links. This is
not the global graph canvas rejected by the research.

## Consequences

Users can audit evidence and dependencies before changing canonical data, and conflicting batches fail without partial
application. Calendar facts retain a stronger provenance boundary than AI-derived organization knowledge.

The schema needs nullable Contact email, revisions, Topic references, proposals, evidence, and dependencies. Contact
tables are rebuilt once in `v26_customerIntelligenceWorkspace` with deferred foreign-key checks. App and MCP database
queues wait up to five seconds for a writer and report lock failures as retryable, all-or-nothing errors. The additive
`v27_customerIntelligenceTopicReferenceTimestamp` migration makes reference cleanup update the Topic timestamp as well
as its revision without changing the already-registered v26 migration.

The view deliberately trades arbitrary graph exploration for predictable performance and clearer customer scope.
