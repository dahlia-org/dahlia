# Database GRDB and Migration Guide

The highest-priority outcome in this subtree is reaching the intended schema while preserving every released user's data.

The production database is at `~/Library/Application Support/Dahlia/dahlia.sqlite` (`AppDatabaseManager.databaseURL`). Never read or write that file during development or testing. Use `AppDatabaseManager(path: ":memory:")` or a temporary path.

## Migration Invariants

- Keep `migrator.eraseDatabaseOnSchemaChange = false`. Destructive schema resets are prohibited.
- Do not change the name, order, or body of any registered `registerMigration`.
- For a schema change, inspect the current final migration and append the required forward migrations named `v<next number>_<purpose>`. Never infer a fixed "next version" from documentation.
- Follow the existing `add...ColumnIfNeeded` pattern for added columns and keep migration work safe to rerun.
- Prepare and test data-preserving table rebuilds on disposable databases within the requested schema change. If the intended migration would delete data or irreversibly change its meaning beyond the authorized request, present the proposed transformation, risks, and a non-destructive alternative before implementing that destructive change. Never apply a migration to production as incidental validation.

## Models and Access

- Keep one table per `<Name>Record.swift` file, conforming to `Codable`, `FetchableRecord`, and `PersistableRecord`.
- UI database access goes through the `@MainActor`-isolated `MeetingRepository`.
- Project identity and hierarchy are canonical in `projects.id` and `parentProjectId + name`. Vault directories are
  derived Summary output locations; filesystem events must never create or restructure Project records.

## Verification

- Add a test for each new migration that starts from the prior schema with existing rows and verifies that values and relationships survive.
- Verify both applying every migration to an empty database and upgrading from the immediately preceding schema.
- Run at least `swift test --filter AppDatabaseManagerTests` plus any migration- or repository-specific tests for the changed behavior.
