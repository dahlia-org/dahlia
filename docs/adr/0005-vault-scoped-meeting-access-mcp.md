# ADR 0005: Vault-scoped read-only meeting access over local MCP

- Status: Accepted
- Date: 2026-07-16

## Context

Dahlia's in-app AI chat and terminal agents such as Claude Code and Codex need one efficient interface for finding meetings, reading summaries, and consulting original transcripts. Direct database access would duplicate schema knowledge and make vault isolation easy to omit.

## Decision

Dahlia ships a signed local stdio helper named `dahlia-mcp`. The process requires `--vault-id <UUID>` at launch and its scope cannot change during its lifetime. The UUID is the authorization boundary; the vault name is display metadata only. Every meeting query predicates on `meetings.vaultId`, and a meeting ID from another vault is reported as not found.

The helper opens Dahlia's SQLite database read-only and never runs migrations, changes permissions, or writes application data. It exposes three tools:

- `query_meetings` searches compact metadata: AI meeting name and description, calendar title, project, and tags. It does not search summary or transcript bodies.
- `get_meeting` returns metadata and the stored Markdown summary, or `null` when absent.
- `get_meeting_transcript` returns paginated confirmed original segments with speaker, absolute timestamps, and elapsed time across recording sessions.

The helper validates the database schema during MCP initialization. After an application update that adds a migration, Dahlia must be opened once before external clients use the helper.

Opaque cursors contain and validate vault, meeting, and ordering identity. Notes, screenshots, audio, translated text, and unconfirmed transcript text are outside the initial interface.

AI summary documents use schema version 3 and add a one-line description of at most 240 characters. Successful summary persistence updates the meeting name with a nonblank generated title of at most 120 characters and updates the meeting description when a nonblank generated value is available. Missing or blank legacy description values preserve the latest useful description. Existing meetings are not backfilled.

The in-app Codex chat disables configured user MCP servers and enables only the bundled Dahlia helper for both thread start and resume. Its workspace and history are separated by vault UUID. A vault switch creates a new floating session; a detached session bound to another vault cannot send until that vault is active again. Summary generation continues to disable every MCP server.

Settings only displays and copies CLI registration commands. It does not edit Claude Code or Codex configuration. Because each external client has a single server named `dahlia`, changing vault means removing and adding that registration with another UUID.

## Consequences

- Both embedded and external agents share the same query semantics and security boundary.
- The initial API remains small and avoids transferring large transcript bodies during discovery.
- Users must explicitly re-register the external MCP server when changing vaults.
- Future write tools, full-text body search, or additional media require a separate security and privacy decision.
