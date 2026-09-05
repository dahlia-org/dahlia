# Desktop Release Versioning

- Apply this policy prospectively when preparing a release. Do not revise or validate historical version numbers, missing releases, or build numbers against it.
- Keep `CFBundleShortVersionString` in `x.y.z` format. Determine the next version from the complete set of changes since the latest release, not from each individual change.
- Increment `z` for a release containing only backward-compatible fixes, improvements, or additions. This includes bug fixes, internal refactoring, documentation, backward-compatible features, and additive database migrations that do not change the meaning of existing data, such as new tables or indexes and nullable or defaulted columns.
- Increment `y` and reset `z` to `0` when a release changes compatibility, a primary workflow, or an existing behavioral or data contract. This includes semantic changes to recording or transcription, changes to existing settings, MCP or backup contracts, table rebuilds, renames or removals, type, nullability, constraint, or relationship changes, and migrations that reinterpret, transform, or meaningfully backfill existing data.
- When a release contains changes from multiple categories, use the highest required increment.
- Never infer an `x.0.0` release. Increment `x` and reset `y` and `z` to `0` only when the user explicitly requests a major version; ask before release if a major increment appears necessary.
- Update versions during release preparation, not as part of ordinary feature or fix changes.
- Treat `CFBundleVersion` as an integer build number independent of the marketing version. Increase it from the latest published build for every newly published distribution artifact, including a replacement with the same marketing version. Local builds and unpublished attempts do not require an increment.
- During release preparation, update `CFBundleShortVersionString` and `CFBundleVersion` together in `Resources/Info.plist`.
