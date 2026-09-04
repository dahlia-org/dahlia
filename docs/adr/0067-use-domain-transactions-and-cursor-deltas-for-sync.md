# ADR-0067: Use domain transactions and cursor deltas for sync

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0056, ADR-0058, ADR-0059, ADR-0066

## Context

Whole-Vault and whole-meeting manifests could create a private Server copy, but they could not safely support edits from both Desktop and Private Web. Retries had no domain idempotency key, concurrent edits used implicit replacement, and Server changes had no durable catch-up contract.

## Decision

- For Server accounts, Server Vaults and Projects are shared canonical SaaS records used by Desktop and Web; they are not a one-way copy destination. Desktop's existing `vaults`, `projects`, `meetings`, `summaries`, `transcript_segments`, and `screenshots` rows are the offline working-copy record cache. A local edit updates that cache and records its retryable domain operation in the same SQLite transaction. Recording and finalized-transcript persistence never wait for network work. Local accounts remain standalone and do not create sync transactions.
- Signing in never moves the current local Vault implicitly. The user explicitly moves it to a Server account, after Dahlia checks whether that Server already exposes the same Vault ID. A new ID starts the normal initial transaction sequence; an existing owner Vault uses the normal revision-conflict resolution, while an existing member Vault can only adopt the Server version. A Server-managed Vault always synchronizes, so there is no separate synchronization toggle.
- Before signing out, the user either removes that account's local working copies or moves them to the Local Account. Both choices leave Server canonical data unchanged; moving clears queued operations, confirmed revisions, and cursors before removing the account association.
- A transaction contains operations for exactly one Vault and is committed atomically by `POST /api/v1/transactions`. Its UUIDv7 ID is the idempotency key; Server stores the committed response and rejects reuse with different content.
- The additional Desktop synchronization schema is limited to four tables: `sync_transactions` stores ordering, lease, retry, and blocking state; `sync_operations` stores immutable operation JSON and optional screenshot bytes; `sync_entity_state` stores only Server-confirmed revisions; and `sync_transcript_patch_items` stores transcript upserts and deletes without serializing the recording critical path to JSON. Pending/running state, expected revisions, and optimistic revisions are derived rather than persisted.
- Vault, Project, meeting metadata, and summary mutations use optimistic revisions. A stale base revision returns `409` with the conflicting entity and canonical Server record. Dahlia does not silently use last-write-wins.
- Screenshot bytes are snapshotted on their immutable operation row. Transcript upserts and deletes are snapshotted as patch items. The worker sends both through bounded staging endpoints before committing the unchanged domain transaction.
- The worker may continue pushing and pulling during recording, but it queues transcript patches only when segments become finalized. Initial snapshot construction uses bounded SQLite writes and yields to recording; if recording or another local mutation starts during construction, the unsent partial snapshot is discarded and rebuilt later from the current working copy.
- Server appends durable per-Vault change rows and returns opaque cursors. A delta catch-up captures a high-water cursor and pages the final canonical state of each changed entity through that boundary, so history is bounded without exposing transient delete/recreate states. Desktop updates confirmed revisions, applies canonical records only when no later optimistic operation exists, saves the commit cursor, and then deletes the acknowledged transaction. Pull checkpoints advance only when the corresponding delta page is applied.
- The main protected-resource metadata advertises `all-apis`, because Desktop both uploads transactions and reads canonical deltas.
- `GET /api/v1/events` is an SSE invalidation channel containing only a cursor. It is never a data source; startup, foreground recovery, reconnect, and missed events all catch up through the cursor-based delta API.
- Local mutation paths call the recorder explicitly. The remote change applier writes canonical rows without invoking that recorder, so remote changes do not create echo operations.
- Validation, revision conflict, authorization, and retryable transport failures are persisted distinctly. Only transport errors, `408`, `425`, `429`, and `5xx` retry automatically; a blocked transaction also blocks later transactions for the same Vault.
- Private Web uses the same transaction endpoint. Server MCP remains read-only.

The synchronization migrations introduced on this unreleased branch are folded into their existing Desktop migration identifiers and the unreleased Server application baselines. Released Desktop migrations remain immutable.

## Consequences

Desktop remains responsive and usable offline while converging on Server canonical state after reconnection. Account boundaries and conflicts require explicit choices; authentication alone never transfers Vault ownership. The four synchronization tables are queue support, not a replacement for the existing local record cache. The durable Server change ledger and idempotency receipts need a retention policy before broad public deployment.
