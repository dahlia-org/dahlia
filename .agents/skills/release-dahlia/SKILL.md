---
name: release-dahlia
description: Prepare and publish a Dahlia macOS desktop-app release with versioning, validation, Japanese and English user-facing notes, Sparkle localization, notarization handoff, and GitHub Release creation. Use when cutting, preparing, publishing, or checking a Dahlia app release; do not use for release notes or releases of the dahlia-mcp executable or unrelated repository modules.
---

# Release Dahlia

Prepare the desktop app release. Keep note generation in this skill; never launch another Codex process from a release script.

## Scope the release

1. Read the repository `AGENTS.md` release policy and `Resources/Info.plist`.
2. Find the latest published GitHub Release tag and inspect every change from that tag through `HEAD`. Ignore later local or remote tags that are not published releases. If no release exists, inspect all reachable release-relevant history.
3. Include only changes that affect the `Dahlia` executable or its installed bundle:
   - Include `Sources/Dahlia`, app resources, and packaging behavior visible to app users.
   - Include shared-target changes only when the `Dahlia` target actually uses the changed behavior.
   - Exclude `DahliaMCP`, `DahliaMeetingAccess`, tests, CI, developer tooling, and docs unless the same change materially affects the desktop app.
4. Determine one version increment from the complete release range. Apply the root release policy; never infer a major version.
5. Stop if a GitHub Release already exists for the target version. An existing target tag at `HEAD` is not the comparison base when that release is still unpublished.
6. Update both version keys in `Resources/Info.plist` only during release preparation. Do not publish until the version change is committed and `HEAD` is pushed.

## Write localized notes

Create `.build/release-notes/Dahlia.ja.md` and `.build/release-notes/Dahlia.en.md`. Express the same supported facts in both languages; write natural text rather than a literal translation.

- Open with one or two sentences stating the main user value.
- Use only applicable headings: Japanese `## ハイライト`, `## 改善`, `## 修正`; English `## Highlights`, `## Improvements`, `## Fixes`.
- Keep three to eight outcome-focused bullets in total.
- Group related commits. Describe what users can do or what became more reliable.
- Mention material compatibility, migration, privacy, performance, reliability, or behavior changes.
- Omit internal module names, implementation types, raw commits, PR inventories, tests, CI, refactors, and dependency churn unless users directly experience the effect.
- End each file with its localized label and the same compare URL when the previous tag and repository URL are available.

Check both files against the inspected diff. Reject any claim that is unsupported or belongs only to an excluded module.

## Validate locally

Run the release-relevant build, tests, and lint required by the repository instructions. Confirm the intended tests ran from their summaries. Review the final diff and require a clean working tree before packaging.

Do not create tags or releases yet.

## Obtain a notarized DMG

Treat Apple notarization as a credentialed external action. Prefer this handoff unless the user explicitly authorizes running it:

```bash
./scripts/notarize.sh
```

Wait for the user to confirm that `Dahlia.dmg` was produced. Do not claim notarization succeeded from submission alone; the script must staple and validate the ticket.

## Publish

Show both note files and the target version to the user. Publishing creates external state, so wait for explicit confirmation, then run:

```bash
./scripts/create-github-release.sh \
  --notes-file-ja .build/release-notes/Dahlia.ja.md \
  --notes-file-en .build/release-notes/Dahlia.en.md
```

The script performs deterministic validation and publishing only. It uploads both notes as signed Sparkle assets; Sparkle selects `ja` or `en` from the user's app language preferences.

After completion, report the GitHub Release URL and the exact validation performed. If credentials or permissions block notarization or publishing, stop and provide the manual command without weakening validation.
