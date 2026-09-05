# Release Scope

1. Find the latest published GitHub Release tag and inspect every change from that tag through `HEAD`. Ignore later local or remote tags that are not published releases. If no release exists, inspect all reachable release-relevant history.
2. Include only changes that affect the `Dahlia` executable or its installed bundle:
   - Include `apps/desktop/Sources/Dahlia`, app resources, and packaging behavior visible to app users.
   - Include shared-target changes only when the `Dahlia` target actually uses the changed behavior.
   - Exclude `DahliaMCP`, `DahliaMeetingAccess`, tests, CI, developer tooling, and docs unless the same change materially affects the app.
3. Determine one version increment from the complete release range. Apply [Desktop Release Versioning](../../../../docs/desktop-release-versioning.md); never infer a major version.
4. Stop if a GitHub Release already exists for the target version. An existing target tag at `HEAD` is not the comparison base when that release is still unpublished.
5. Update both version keys in `Resources/Info.plist` only during release preparation.
