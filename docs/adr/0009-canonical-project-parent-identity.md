# ADR 0009: Canonical Project hierarchy uses stable parent identity

## Status

Accepted

## Context

Project hierarchy was derived from a slash-delimited relative path stored in `projects.name`. Rename and reparent
therefore changed the value used as both identity context and filesystem location, required prefix rewrites for every
descendant, and made it difficult to express type inheritance or optimistic concurrency safely. The physical directory
tree must still match the Project tree.

Future Organization and Person associations need a Project identity that does not change when a workspace is renamed or
moved. Those associations are not part of this change.

## Decision

Use `projects.id` as stable identity and `parentProjectId + leafName` as the canonical hierarchy. A persisted internal
`leafNameKey` materializes one Unicode normalization and case-folding contract for sibling uniqueness. All supported
writers—the app repository, sync, migration, and MCP—derive it with `DahliaProjectName`; direct SQL is not a supported
mutation interface. Derive Vault-relative paths at read and operation-planning time. The filesystem mirrors that
derived hierarchy but is not an independent canonical relationship.

Only roots store an explicit `projectType`; descendants derive effective type from their root. Each Project carries a
monotonic `revision` used by external updates. Database constraints and triggers enforce sibling uniqueness, same-Vault
parents, no cycles, root-only explicit type, immutable Vault ownership, and same-Vault Meeting membership.

Filesystem-plus-database mutations use a shared Vault lock, complete prevalidation, a single database transaction, and
filesystem compensation on failure. External mutation capability is selected only by the presence of `--write`.

## Alternatives considered

### Keep the relative path as canonical

This avoids a migration, but every ancestor rename changes the hierarchy key of all descendants and makes future stable
foreign-key associations harder to reason about. It was rejected.

### Store both a canonical parent ID and a canonical path

This makes two database fields authoritative for the same relationship and requires every code path, FSEvent, and
external client to update both perfectly. It was rejected because ordinary failures can create split-brain hierarchy.

### Put a hidden UUID file in every directory

This could preserve identity across every offline Finder move, but adds hidden Vault artifacts and a second
synchronization protocol. It was rejected for this iteration. Correlated live Finder moves preserve identity; ambiguous
offline moves are synchronized as directory discoveries/missing Projects. UUID preservation is guaranteed for app and
MCP operations.

### Give every Project an explicit type

Materializing inherited values makes reparent and root type changes fan out as data rewrites and permits contradictory
child values. It was rejected in favor of a nullable root-owned explicit value and derived effective value.

## Consequences

- Existing path rows are migrated into explicit ancestors while retaining every existing Project UUID.
- Legacy siblings that collide only after normalization are deterministically suffixed and marked missing for review,
  preserving startup, UUIDs, same-Vault Meeting membership, metadata, and repaired Summary export paths without
  claiming a mismatched directory.
- Rename and reparent update one hierarchy edge, affected revisions, directories, and Summary export paths.
- Reads must resolve paths and effective types.
- Organization and Person tables can later reference stable Project IDs without coupling to paths.
- Project deletion/merge remains outside writable MCP until recovery semantics are designed.
