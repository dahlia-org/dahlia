---
name: release-dahlia-app
description: Prepare and publish a Dahlia macOS app release with versioning, optional local revalidation, Japanese and English user-facing notes, Sparkle localization, notarization, and GitHub Release creation. Use when cutting, preparing, publishing, or checking a Dahlia app release; do not use for releases of the dahlia-mcp executable or unrelated repository modules.
---

# Release Dahlia App

Prepare the desktop app release. Keep note generation in this skill; never launch another Codex process from a release script.

## Scope the release

Read the repository `AGENTS.md` release policy, `Resources/Info.plist`, and [references/release-scope.md](references/release-scope.md). Apply the reference to determine the release range, included changes, and version. Do not publish until the version change is committed and `HEAD` is pushed.

## Write localized notes

Read and apply [references/release-notes.md](references/release-notes.md). Create the reviewed Japanese and English notes before validation and publishing.

## Validate locally

Run the release-relevant build, tests, and lint required by the repository instructions. Confirm the intended tests ran from their summaries.

If the user invokes `$release-dahlia-app --skip-local-validation`, do not rerun the validation build, tests, or lint. Report those checks as skipped at the user's request; do not describe earlier checks as passing unless their results are available. This option never skips final diff review, the clean-working-tree requirement, the release build used to package the DMG, notarization checks, release-asset validation, or publishing validation.

Review the final diff and require a clean working tree before packaging.

Do not create tags or releases yet.

## Obtain a notarized DMG

When the user asks to cut or publish a release, build and notarize the DMG by default without asking for separate confirmation:

```bash
.agents/skills/release-dahlia-app/scripts/notarize.sh
```

Do not run notarization for a check, explanation, or preparation-only request. If the user supplies an already-notarized `Dahlia.dmg`, do not rebuild it; continue with the publishing script's validation. Do not claim notarization succeeded from submission alone; the script must staple and validate the ticket. If credentials are unavailable, stop and provide the command for the user to run.

## Publish

Show both note files and the target version to the user. Publishing creates external state, so wait for explicit confirmation, then run:

```bash
.agents/skills/release-dahlia-app/scripts/create-github-release.sh \
  --notes-file-ja .build/release-notes/release-note-ja.md \
  --notes-file-en .build/release-notes/release-note-en.md
```

The script performs deterministic validation and publishing only. The GitHub Release body uses the English notes. It also uploads both notes as `release-note-ja.md` and `release-note-en.md`; Sparkle selects `ja` or `en` from the user's app language preferences.

After completion, report the GitHub Release URL and the exact validation performed. If credentials or permissions block notarization or publishing, stop and provide the manual command without weakening validation.
