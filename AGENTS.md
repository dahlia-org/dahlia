# Dahlia Repository Guide

## Goal

Dahlia is a macOS app that captures microphone and system audio simultaneously, transcribes it in real time with the Apple Speech framework, and can optionally generate LLM summaries.

Complete the requested outcome while preserving recording and transcription quality, user data, and behavior that the request does not explicitly change.

## Instruction Scope

This file applies to the entire repository. Before editing a path covered by a more specific `AGENTS.md`, read that file and follow its additional instructions.

| Scope | Additional guidance |
| --- | --- |
| `Sources/Dahlia/` | Architecture, concurrency, and UI: `Sources/Dahlia/AGENTS.md` |
| `Sources/Dahlia/Database/` | GRDB and migrations: `Sources/Dahlia/Database/AGENTS.md` |
| `Tests/DahliaTests/` | Test implementation and verification: `Tests/DahliaTests/AGENTS.md` |
| `scripts/` | SwiftPM build, signing, notarization, and lint scripts |

`CLAUDE.md` imports the `AGENTS.md` in the same directory with `@AGENTS.md`. Do not maintain duplicate content.

## Documentation Router

Use progressive disclosure: read the scoped `AGENTS.md` first, then open only the references required by the task.

| Task | Additional reference |
| --- | --- |
| Whether to build something, its product scope, or how AI and the user divide the work | [`PRODUCT.md`](PRODUCT.md), then the [`Tenets`](PRODUCT.md#tenets) that the change touches |
| Current runtime ownership or workload boundaries | [`ARCHITECTURE.md`](ARCHITECTURE.md#runtime-data-flow) |
| Audio capture, recording, live subtitles, or realtime/batch transcript data flow | [`Audio and Transcription Data Flow`](docs/architecture/audio-transcription-data-flow.md) |
| Recording, transcription, concurrency, persistence, or failure handling | [`ARCHITECTURE.md`](ARCHITECTURE.md#reliability-scope), then the relevant section |
| UI interaction, rendering workload, or responsiveness | [`Sources/Dahlia/AGENTS.md`](Sources/Dahlia/AGENTS.md), then [`UI and Interaction Responsiveness`](ARCHITECTURE.md#ui-and-interaction-responsiveness) when workload behavior is affected |
| Code review | [`Code Review Guide`](docs/code-review.md), then the architecture references routed by the closest applicable `AGENTS.md` |
| Fixing an identified architecture deviation | [`Conformance Status`](ARCHITECTURE.md#conformance-status), then the matching item in [`Remediation Plan`](ARCHITECTURE.md#remediation-plan) |
| Historical rationale or a change to an architectural decision | [`docs/adr/README.md`](docs/adr/README.md), then only the relevant ADR |

Do not read every ADR by default. `PRODUCT.md` decides what to build and what to refuse; `ARCHITECTURE.md` describes
the current system, target state, and conformance gaps; ADRs preserve decision history; and `AGENTS.md` contains
actionable instructions. Keep detailed architecture out of `AGENTS.md` except for short safety invariants whose
omission could cause data loss.

A change that conflicts with a product tenet is not resolved by editing `PRODUCT.md` to match the change. Report the
conflict, and update the tenet only through a new ADR that the user approves.

## Engineering Constraints

- **IMPORTANT:** Do not write overly defensive code. Always prefer simplicity over pathological complexity.
- Use Swift 6.2, SwiftUI, macOS 26+, and Swift 6 strict concurrency.
- Use Swift Package Manager only. Do not generate an Xcode project.
- The app has exactly four SwiftPM runtime dependencies: GRDB.swift, sentry-cocoa, Sparkle, and WhisperKit. The separate `BuildTools` package pins SwiftFormat. The app also verifies and bundles a pinned official arm64 release of the OpenAI Codex CLI as a runtime helper. Get confirmation before adding or updating dependencies.
- Never destroy a released user's database. Do not modify registered migrations; add a new migration according to `Sources/Dahlia/Database/AGENTS.md`.

## Code Review Rules

- Before reporting findings, read [`docs/code-review.md`](docs/code-review.md) and the architecture sections routed by the closest applicable `AGENTS.md`.
- Report only actionable defects introduced or exposed by the change. Each finding must identify a reachable trigger, the concrete impact, and the violated Dahlia contract or missing validation. Do not report style, formatting, or other deterministic checks enforced by CI.
- Prioritize recording and transcription integrity, released-user data, correctness, security, and sustained responsiveness. Do not trade durable or recording-critical data for UI performance; bound, coalesce, cancel, or rebuild only projection work whose source of truth is preserved.

## Release Versioning

- Apply this policy prospectively when preparing a release. Do not revise or validate historical version numbers, missing releases, or build numbers against it.
- Keep `CFBundleShortVersionString` in `x.y.z` format. Determine the next version from the complete set of changes since the latest release, not from each individual change.
- Increment `z` for a release containing only backward-compatible fixes, improvements, or additions. This includes bug fixes, internal refactoring, documentation, backward-compatible features, and additive database migrations that do not change the meaning of existing data, such as new tables or indexes and nullable or defaulted columns.
- Increment `y` and reset `z` to `0` when a release changes compatibility, a primary workflow, or an existing behavioral or data contract. This includes semantic changes to recording or transcription, changes to existing settings, MCP or backup contracts, table rebuilds, renames or removals, type, nullability, constraint, or relationship changes, and migrations that reinterpret, transform, or meaningfully backfill existing data.
- When a release contains changes from multiple categories, use the highest required increment.
- Never infer an `x.0.0` release. Increment `x` and reset `y` and `z` to `0` only when the user explicitly requests a major version; ask before release if a major increment appears necessary.
- Update versions during release preparation, not as part of ordinary feature or fix changes.
- Treat `CFBundleVersion` as an integer build number independent of the marketing version. Increase it from the latest published build for every newly published distribution artifact, including a replacement with the same marketing version. Local builds and unpublished attempts do not require an increment.
- During release preparation, update `CFBundleShortVersionString` and `CFBundleVersion` together in `Resources/Info.plist`.

## Authorization

- For requests to answer, explain, review, diagnose, or plan, inspect the relevant files and logs and report the result. Do not edit unless the request also asks for a change.
- For requests to change, implement, or fix, make the in-scope local edits and run relevant non-destructive validation without asking first. Preserve existing uncommitted work and leave unrelated changes untouched.
- Get confirmation before destructive actions, external writes, dependency changes, or a material expansion of scope.
- When asking the user a question, treat it as blocking and wait for an explicit response. Do not resolve it automatically through a timeout, default, or recommended choice. If the active agent or tool provides wait-duration or automatic-resolution controls, configure them for indefinite waiting or disable automatic resolution. If that is not supported, leave the question unresolved and stop rather than proceeding without the user's answer.
- When a requested GitHub operation requires GitHub CLI access to existing authentication credentials, agents may run the necessary `gh` commands outside the sandbox without additional confirmation. Use the environment's supported escalation mechanism, keep access scoped to the requested operation, and never reveal, export, copy, or persist credential values. Reauthentication or other changes to authentication state still require explicit user authorization.

## Commands

```bash
swift build                            # Debug build
swift run Dahlia                       # Unsigned debug run
./scripts/run-dev.sh                   # Debug + codesign; preferred for full-feature testing
./scripts/build-app.sh                 # Release .app bundle
swift test                             # Full test suite
swift test --filter SummaryServiceTests # Example targeted suite
CI=true ./scripts/lint.sh              # Check SwiftFormat and SwiftLint without modifying files
```

`swift run Dahlia` is unsigned and cannot use the Data Protection Keychain. Use `./scripts/run-dev.sh` to verify Keychain or Touch ID behavior.

## Definition of Done

- The requested outcome and all applicable repository instructions are satisfied.
- Swift changes pass `swift build`, behavior changes pass targeted tests, and broader changes run `swift test` when warranted. Swift source changes also pass `CI=true ./scripts/lint.sh`.
- Confirm from the test summary—not only exit code 0—that the intended tests actually ran.
- Changes to public behavior, settings, or schemas include the corresponding tests, localization, and documentation.
- Review the final diff against the applicable Code Review Rules for unintended changes and regressions.
- If a check cannot run, report the exact command, reason, and next verification step. Do not describe an unverified check as passing.
