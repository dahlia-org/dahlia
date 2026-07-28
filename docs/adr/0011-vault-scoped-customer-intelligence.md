# ADR 0011: Customer intelligence is Vault-scoped, typed, and separated from AI assertions

## Status

Accepted; amends ADR 0005 and builds on ADR 0010. The Glossary portion was superseded by
[ADR 0012](0012-reviewable-customer-intelligence-workspace.md) and removed from the unreleased v25/v26 schema before
release.

The Glossary references below describe the original design exploration and are retained as decision history; they were
never part of a released product, database, or MCP contract.

## Context

Dahlia needs to analyze meeting history by customer, person, organizational unit, project, and terminology. Calendar
attendees provide a useful identity seed, while summaries and transcripts can later produce hypotheses such as decision
makers, risks, or organizational changes.

Those inputs have different stability. An attendee email and an explicit membership are canonical local data; an
LLM-generated statement, confidence, or rank can be regenerated and may require review. Treating both as columns on one
generic entity would weaken foreign keys, make AI output shape part of the durable schema, and allow acceptance of an
assertion to silently rewrite customer data.

Contact identity also has two different scopes. A local installation should stay simple, but a future cloud service may
combine multiple users and Vaults. A globally unique local email registry would leak display names and inferred
relationships across Vaults, while a local UUID cannot safely serve as the cloud-wide person identity.

## Decision

Keep stable concepts in typed SQLite tables:

- `contacts` uses a UUIDv7 primary key and `UNIQUE(vaultId, email)`. One canonical primary email is stored in v1.
- `organizations` represents both Organizations and units through immutable `nodeKind` plus
  `parentOrganizationId`. Roots must be Organizations. The hierarchy has a 32-edge query and mutation limit.
- `organization_domains` allows multiple canonical ASCII domains per Organization. Supported Repository and ingestion
  writes keep exactly one primary whenever domains exist; deleting it deterministically promotes the oldest remaining
  domain. The partial unique index enforces at most one primary, while direct raw SQL is not a supported write API.
- `organization_memberships` is many-to-many and has no primary membership, so concurrent assignments are representable.
- `meeting_participants` links calendar-derived Contacts to Meetings and stores role, response state, and source.
- `project_resource_references` relates a Project to an Organization, unit, or Contact without making one organization
  foreign key canonical for every Project.
- `glossary_terms` stores stable terms and definitions.
- `insights` stores assertions and a Boolean acceptance flag. Rank, confidence, model, prompt, provenance, review timestamps, and
  other evolving attributes stay in `metadataJSON` until their semantics are stable.

Only Contacts, Organizations, domains, memberships, and Meeting participants have an automatic production writer in
v1. Project resource references, Insights, and Glossary terms intentionally ship as a schema-first foundation with
Repository APIs and read-only MCP tools, but no automatic extractor or user-facing writer. They can therefore remain
empty until a later producer is added.

The local email and domain invariant is trim, lowercase, validate, and store. Lowercasing the local part is an explicit
practical identity choice even though SMTP permits case-sensitive local parts. v1 rejects non-ASCII email addresses and
domains because Dahlia does not add an IDNA dependency. Column names describe the stored concept (`email`,
`domainName`), not the normalization procedure. The canonicalizer lives in `DahliaRuntimeSupport` rather than the app
target so the app and separately built MCP access layer can share one implementation. The read-only v1 access store
returns persisted canonical values without re-normalizing them.

The first observation of a non-public attendee domain creates an Organization whose initial editable name is the domain.
Later observations update domain freshness but never overwrite a user-edited Organization name. Public mailbox domains
such as Gmail create Contacts but do not create Organizations automatically. Every Meeting materialization call site
must explicitly choose whether ingestion runs after Meeting persistence or only after capture starts. Ordinary
calendar-linked Meetings use the former; recording flows use the latter. Existing Meetings and all Calendar events are
not backfilled.

Domains use the complete canonical host after `@`; Dahlia does not calculate a registrable domain. For example,
`mail.example.co.jp` and `example.co.jp` identify different Organizations. The public-mailbox check is a best-effort
curated provider list rather than a complete public-suffix or mailbox-provider database. The list is updated manually
through reviewed source changes when a false positive or false negative is identified; it has no completeness guarantee.
Unrecognized domains may initially create an Organization and can be corrected through the same explicit Organization
operations. This avoids adding a network lookup or dependency to the ingestion path.

ADR 0010 limits Project workspaces to a root plus one subproject because their hierarchy drives product UI, inheritance,
and derived Summary paths. That depth decision does not apply to enterprise Organizations. Organization hierarchy models
real company structures and uses 32 edges as an operational and corruption bound, not as an intended business depth.

Insight, Glossary, and Project resource links use typed polymorphic references. SQLite triggers validate target
existence and Vault equality on insert and update. Since a polymorphic foreign key cannot be declared, target deletion
triggers remove references. Readers tolerate a missing resolved display name as corrupted or concurrently deleted data,
but never resolve it from another Vault. `relationLabel` uses an empty string for an unlabeled relation so its composite
unique constraint also deduplicates unlabeled links; SQLite `NULL` would not.

Changing an Insight's acceptance flag changes only the Insight and optional metadata. It never mutates an Organization,
Contact, membership, Project relation, Meeting, or Glossary term. A future write-back must be a separate explicit
operation with its own validation.

Extend the local MCP with read-only, Vault-scoped tools for Organizations, Contacts, Project resources, Insights, and
Glossary terms. Keep them unavailable in Meeting-limited sessions. Bounded queries use a maximum of 100 results and
keyset cursors bound to the Vault and normalized filter set. Nested Organizations, memberships, Project links, Insight
references, and Glossary references return at most 100 rows plus an explicit truncation flag; recent Contact Meetings
return at most 25. Contact interaction counts, last interaction, and recent Meeting lists exclude declined participants
and are derived from `meeting_participants` joined to Meetings, supported by
`meeting_participants(contactId, meetingId)` and the existing Vault/creation-time Meeting index. Interaction time is the
Meeting record's `createdAt`, which normally approximates recording start; it is not the linked calendar event's
scheduled start.

Contact and Organization MCP responses include names and complete primary email addresses. Invoking those tools makes
that personal data available to the configured in-app or external agent within the selected Vault. The MCP instructions
require email addresses to be used only for identity or disambiguation and not repeated unnecessarily. v1 does not add a
per-Contact review or deletion UI; deleting the Vault remains the only user-facing bulk removal path.

## Alternatives considered

### Use email as the Contact primary key

This is locally simple but makes email correction and future multi-email identity difficult, and it embeds a mutable
external identifier into every relationship. It was rejected in favor of a local UUID plus one v1 email.

### Use a global local Contact registry

This deduplicates Contacts across Vaults, but it lets one Vault fill or influence another Vault's display name and
relationships. It was rejected. A future cloud service must issue its own stable identity and map source Vault/local
UUID/email evidence explicitly.

### Add multiple local emails and Contact merge now

This is useful eventually, but it adds alias ownership, conflict resolution, merge, split, and migration semantics
before the first feature needs them. It was deferred. A later merge must rewrite and deduplicate
`meeting_participants`, `organization_memberships`, Project resource references, Insight references, and Glossary
references in one transaction.

### Store Organizations and units in separate tables

Separate tables make a Contact's membership target polymorphic and complicate one hierarchy. It was rejected in favor
of one typed hierarchy table with enforced root and parent rules.

### Make a generic ontology entity/edge model canonical

This is flexible but removes useful foreign keys and stable typed repository APIs. It was rejected for canonical data.
Typed generic reference tables remain appropriate for evolving cross-resource links.

### Add first-class snippet, rank, confidence, or reviewed-at columns

The extraction and review workflow is not stable enough to freeze those fields. It was rejected for v1; metadata can
preserve experiments without coupling canonical records to them.

## Consequences

- The same email can identify different local Contact UUIDs in different Vaults, with no cross-Vault name completion.
- One Contact may belong to multiple Organizations or units, and one Organization may own multiple domains.
- Organization kind is immutable; changing an Organization into a unit requires an explicit future migration rather
  than implicit domain deletion.
- The Vault identity of Contacts, Meetings, Insights, and Glossary terms is immutable after insertion, preventing an
  existing typed relation from being moved across a Vault boundary.
- Invalid IDNA input is skipped during calendar ingestion and rejected by explicit repository writes.
- Deleting an Organization through the Repository deletes its descendants from the leaves upward so the self-referencing
  hierarchy and polymorphic-reference cleanup triggers remain consistent.
- Customer-intelligence ingestion is best effort after the core Meeting transaction. For a recording, it is scheduled
  only after capture starts successfully; ordinary calendar materialization schedules it after Meeting creation. Its
  failure is sanitized and reported but never rolls back a successfully created Meeting or interrupts recording startup.
- Generic references cannot become orphans through supported deletion paths, and deletion behavior is covered by tests.
- Insight acceptance remains auditable and reversible because it does not conflate assertion review with canonical
  mutation.
- UI editing, historical backfill, Contact merge, relationship scores, automatic Insight generation, and cloud identity
  resolution remain separate future work.
