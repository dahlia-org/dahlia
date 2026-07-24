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

`CLAUDE.md` is a compatibility symlink to the `AGENTS.md` in the same directory. Do not maintain duplicate content.

## Documentation Router

Use progressive disclosure: read the scoped `AGENTS.md` first, then open only the references required by the task.

| Task | Additional reference |
| --- | --- |
| Current runtime boundaries or data flow | [`ARCHITECTURE.md`](ARCHITECTURE.md#runtime-data-flow) |
| Recording, transcription, concurrency, persistence, or failure handling | [`ARCHITECTURE.md`](ARCHITECTURE.md#reliability-scope), then the relevant section |
| UI interaction, rendering workload, or responsiveness | [`Sources/Dahlia/AGENTS.md`](Sources/Dahlia/AGENTS.md), then [`UI and Interaction Responsiveness`](ARCHITECTURE.md#ui-and-interaction-responsiveness) when workload behavior is affected |
| Fixing an identified architecture deviation | [`Conformance Status`](ARCHITECTURE.md#conformance-status), then the matching item in [`Remediation Plan`](ARCHITECTURE.md#remediation-plan) |
| Historical rationale or a change to an architectural decision | [`docs/adr/README.md`](docs/adr/README.md), then only the relevant ADR |

Do not read every ADR by default. `ARCHITECTURE.md` describes the current system, target state, and conformance gaps;
ADRs preserve decision history; and `AGENTS.md` contains actionable instructions. Keep detailed architecture out of
`AGENTS.md` except for short safety invariants whose omission could cause data loss.

## Engineering Constraints

- **IMPORTANT:** Do not write overly defensive code. Always prefer simplicity over pathological complexity.
- Use Swift 6.2, SwiftUI, macOS 26+, and Swift 6 strict concurrency.
- Use Swift Package Manager only. Do not generate an Xcode project.
- The app has exactly four SwiftPM runtime dependencies: GRDB.swift, sentry-cocoa, Sparkle, and WhisperKit. The separate `BuildTools` package pins SwiftFormat. The app also verifies and bundles a pinned official arm64 release of the OpenAI Codex CLI as a runtime helper. Get confirmation before adding or updating dependencies.
- Never destroy a released user's database. Do not modify registered migrations; add a new migration according to `Sources/Dahlia/Database/AGENTS.md`.

## Authorization

- For requests to answer, explain, review, diagnose, or plan, inspect the relevant files and logs and report the result. Do not edit unless the request also asks for a change.
- For requests to change, implement, or fix, make the in-scope local edits and run relevant non-destructive validation without asking first. Preserve existing uncommitted work and leave unrelated changes untouched.
- Get confirmation before destructive actions, external writes, dependency changes, or a material expansion of scope.

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
- Review the final diff for unintended changes and regressions.
- If a check cannot run, report the exact command, reason, and next verification step. Do not describe an unverified check as passing.
