# ADR 0010: Project hierarchy is database-canonical, bounded, and independent from output directories

## Status

Accepted; amends ADR 0005

## Context

Project hierarchy was derived from a slash-delimited relative path stored in `projects.name`. Rename and reparent
therefore changed a value used as both identity context and filesystem location, required prefix rewrites for every
descendant, and made type inheritance and optimistic concurrency difficult to express safely.

An initial replacement design treated the physical directory tree as a mirror that could also create or repair Project
records through filesystem events. In practice, Project is a meeting-organizing workspace rather than a directory
catalog. Directory identity is inherently ambiguous after offline Finder changes, and bidirectional synchronization
would make SQLite and the filesystem competing sources of truth.

The supported product hierarchy is a root Project plus at most one subproject level. Summary files still need a
predictable Project-oriented export destination, but creating a Project does not itself require filesystem output.

Future Organization and Person associations need a Project identity that does not change when a workspace is renamed or
moved. Those associations are not part of this change.

## Decision

Use `projects.id` as stable identity and `parentProjectId + name` as the canonical hierarchy. A persisted internal
`nameKey` materializes one Unicode normalization and case-folding contract for sibling uniqueness. All supported
writers—the app repository, migration, and MCP—derive it with `DahliaProjectName`; direct SQL is not a supported
mutation interface. Derive logical Vault-relative paths at read and operation-planning time instead of storing a second
canonical path.

Limit hierarchy to roots and one subproject level. A subproject can only reference a same-Vault root and cannot have
children. Enforce this at the database boundary as well as in repositories, services, UI choices, and MCP mutations.

Only roots store an explicit `projectType`; descendants derive effective type from their root. Each Project carries a
monotonic `revision` used by external updates. Database constraints and triggers enforce sibling uniqueness, valid root
parents, root-only explicit type, immutable Vault ownership, and same-Vault Meeting membership.

Treat Project-oriented directories as derived Summary output destinations only. Project creation does not create a
directory. Project rename and reparent may move tracked Summary files that already follow the old derived path, creating
the new output directory lazily. They do not move whole directories or unrelated files. Filesystem events may maintain
tracked Summary export paths, but they never create, rename, reparent, delete, or identify Project records.

Summary-filesystem-plus-database mutations use a shared Vault lock, complete prevalidation, a single database
transaction, and filesystem compensation on failure. External mutation capability is selected only by the presence of
`--write`.

## Alternatives considered

### Keep the relative path as canonical

This avoids a migration, but every ancestor rename changes the hierarchy key of all descendants and makes future stable
foreign-key associations harder to reason about. It was rejected.

### Store both a canonical parent ID and a canonical path

This makes two database fields authoritative for the same relationship and requires every writer to update both
perfectly. It was rejected because ordinary failures can create split-brain hierarchy.

### Bidirectionally synchronize the directory tree

Hidden UUID markers or event correlation could recover some Finder moves, but this creates a second identity protocol
and still leaves ambiguous offline changes. It was rejected because directories are output locations, not Project
entities. External directory changes must not mutate the logical Project tree.

### Support arbitrary hierarchy depth

Arbitrary depth is structurally flexible, but it adds UI, reparent, inheritance, migration, and conflict complexity that
the intended customer/project workspace model does not need. It was rejected in favor of one explicit subproject level
enforced consistently at every boundary.

### Give every Project an explicit type

Materializing inherited values makes reparent and root type changes fan out as data rewrites and permits contradictory
subproject values. It was rejected in favor of a nullable root-owned explicit value and derived effective value.

## Consequences

- Existing path rows migrate into parent/name records while retaining every existing Project UUID.
- Projects deeper than one subproject level flatten directly under their original root. Flattening collisions receive
  deterministic suffixes; UUIDs, descriptions, creation dates, and same-Vault Meeting memberships survive.
- Obsolete Project directory-sync and legacy-context columns are discarded. Existing `CONTEXT.md` files are ignored.
- Existing Summary files are not moved during flattening. Their stored paths remain legacy output locations.
- Rename and reparent update one hierarchy edge, affected revisions, and only aligned tracked Summary paths/files.
- Missing, renamed, or newly created directories do not change Project records.
- Reads must resolve paths and effective types.
- Organization and Person tables can later reference stable Project IDs without coupling to paths.
- Project deletion/merge remains outside writable MCP until recovery semantics are designed.
