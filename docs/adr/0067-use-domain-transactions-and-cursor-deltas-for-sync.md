# ADR-0067: Use domain transactions and cursor deltas for sync

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0056, ADR-0058, ADR-0059, ADR-0066

## Context

Whole-Vault and whole-meeting manifests could create a private Server copy, but they could not safely support edits from both Desktop and Private Web. Retries had no domain idempotency key, concurrent edits used implicit replacement, and Server changes had no durable catch-up contract.

## Decision

- Desktop commits a local edit and its retryable domain operation in the same SQLite transaction. Recording and finalized-transcript persistence never wait for network work.
- A transaction contains operations for exactly one Vault and is committed atomically by `POST /api/v1/transactions`. Its UUIDv7 ID is the idempotency key; Server stores the committed response and rejects reuse with different content.
- Vault, Project, meeting metadata, and summary mutations use optimistic revisions. A stale base revision returns `409` with the conflicting entity and canonical Server record. Dahlia does not silently use last-write-wins.
- Screenshot bytes and transcript chunks continue to use their bounded staging endpoints. A domain transaction activates their metadata or transcript generation.
- Server appends durable per-Vault change rows and returns opaque cursors. Desktop applies canonical records and the cursor before deleting the corresponding queue transaction.
- The main protected-resource metadata advertises `all-apis`, because Desktop both uploads transactions and reads canonical deltas.
- `GET /api/v1/events` is an SSE invalidation channel containing only a cursor. It is never a data source; startup, foreground recovery, reconnect, and missed events all catch up through the cursor-based delta API.
- Applying a remote delta suppresses Desktop sync triggers for the same SQLite transaction, preventing echo operations.
- Private Web uses the same transaction endpoint. Server MCP remains read-only.

The synchronization migrations introduced on this unreleased branch are folded into their existing Desktop migration identifiers and the unreleased Server application baselines. Released Desktop migrations remain immutable.

## Consequences

Desktop remains responsive and usable offline while converging on Server canonical state after reconnection. Conflicts require an explicit Server-version or reapply-local choice. The durable change ledger and idempotency receipts add database state that will need a retention policy before broad public deployment.
