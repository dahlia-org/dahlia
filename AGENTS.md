# Dahlia Repository Guide

## Goal

Dahlia is a macOS app that captures microphone and system audio simultaneously, transcribes it in real time with the Apple Speech framework, and can optionally generate LLM summaries.

Complete the requested outcome while preserving recording and transcription quality, user data, and behavior that the request does not explicitly change.

## Instruction Scope

This file applies to the entire repository. Before editing a path covered by a more specific `AGENTS.md`, read that file and follow its additional instructions.

| Scope | Additional guidance |
| --- | --- |
| `apps/desktop/Sources/Dahlia/` | Architecture, concurrency, and UI: `apps/desktop/Sources/Dahlia/AGENTS.md` |
| `apps/desktop/Sources/Dahlia/Database/` | GRDB and migrations: `apps/desktop/Sources/Dahlia/Database/AGENTS.md` |
| `apps/desktop/Tests/DahliaTests/` | Test implementation and verification: `apps/desktop/Tests/DahliaTests/AGENTS.md` |
| `apps/desktop/scripts/` | SwiftPM build, signing, notarization, and lint implementations |
| `scripts/` | Root compatibility entrypoints for desktop tooling |

`CLAUDE.md` imports the `AGENTS.md` in the same directory with `@AGENTS.md`. Do not maintain duplicate content.

## Documentation Router

Use progressive disclosure: read the scoped `AGENTS.md` first, then open only the references required by the task.

| Task | Additional reference |
| --- | --- |
| Documentation navigation, ownership, or cleanup | [`Documentation index`](docs/README.md) |
| Whether to build something, its product scope, or how AI and the user divide the work | [`PRODUCT.md`](PRODUCT.md), then the [`Tenets`](PRODUCT.md#tenets) that the change touches |
| Current runtime ownership or workload boundaries | [`ARCHITECTURE.md`](ARCHITECTURE.md#runtime-data-flow) |
| Audio capture, recording, live subtitles, or realtime/batch transcript data flow | [`Audio and Transcription Data Flow`](docs/architecture/audio-transcription-data-flow.md) |
| Recording, transcription, concurrency, persistence, or failure handling | [`ARCHITECTURE.md`](ARCHITECTURE.md#reliability-scope), then the relevant section |
| UI interaction, rendering workload, or responsiveness | [`apps/desktop/Sources/Dahlia/AGENTS.md`](apps/desktop/Sources/Dahlia/AGENTS.md), then [`UI and Interaction Responsiveness`](ARCHITECTURE.md#ui-and-interaction-responsiveness) when workload behavior is affected |
| Telemetry, metrics, analytics, Sentry, or external diagnostics | [`Anonymous Telemetry Collection Policy`](docs/telemetry.md), then [許可した集計](docs/adr/desktop/telemetry.md#許可した集計) and [収集と実行境界](docs/adr/desktop/telemetry.md#収集と実行境界) |
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
- The app has exactly eight SwiftPM runtime dependencies: GRDB.swift, sentry-cocoa, TelemetryDeck SwiftSDK, Sparkle, WhisperKit, mlx-swift, mlx-swift-lm, and swift-transformers. Vendored native targets are DahliaAEC3 and the arm64 DahliaLindera static XCFramework (Rust 1.97.0, Lindera 2.0.1, embedded IPADIC, and a committed Cargo.lock). The separate `apps/desktop/BuildTools` package pins SwiftFormat. The app also verifies and bundles a pinned official arm64 release of the OpenAI Codex CLI as a runtime helper. Get confirmation before adding or updating dependencies unless the user has already authorized the specific dependency change.
- Telemetry is allowlist-only and best-effort. Follow [`docs/telemetry.md`](docs/telemetry.md): never send content, identifiers, paths, or free text; never wait for delivery; and never call a telemetry SDK outside its designated adapter.
- Never destroy a released user's database. Do not modify registered migrations; add a new migration according to `apps/desktop/Sources/Dahlia/Database/AGENTS.md`.

## Code Review Rules

- Before reporting findings, read [`docs/code-review.md`](docs/code-review.md) and the architecture sections routed by the closest applicable `AGENTS.md`.
- Report only actionable defects introduced or exposed by the change. Each finding must identify a reachable trigger, the concrete impact, and the violated Dahlia contract or missing validation. Do not report style, formatting, or other deterministic checks enforced by CI.
- Prioritize recording and transcription integrity, released-user data, correctness, security, and sustained responsiveness. Do not trade durable or recording-critical data for UI performance; bound, coalesce, cancel, or rebuild only projection work whose source of truth is preserved.
- Treat new telemetry fields and SDK calls as privacy and responsiveness changes. Reject values outside the telemetry policy and any path that can gate recording, persistence, or UI completion.

## Release Versioning

Update versions only during desktop release preparation. Follow [Desktop Release Versioning](docs/desktop-release-versioning.md) for the release range, compatibility increment, and build number.

## Authorization

- For requests to answer, explain, review, diagnose, or plan, inspect the relevant files and logs and report the result. Do not edit unless the request also asks for a change.
- For requests to change, implement, or fix, make the in-scope local edits and run relevant non-destructive validation without asking first. Preserve existing uncommitted work and leave unrelated changes untouched.
- Get confirmation for destructive actions, external writes, dependency changes, or material scope expansions that the user has not already authorized. An explicit request authorizes its in-scope operation; do not ask again solely because it writes externally. Preserve any action-time approval required by the execution environment.
- Ask only when a missing decision materially affects correctness, safety, or scope. Keep dependent work pending until the user answers, and continue independent authorized work. Never treat a timeout, default, or recommendation as the user's approval.
- When a requested GitHub operation requires GitHub CLI access to existing authentication credentials, agents may run the necessary `gh` commands outside the sandbox without additional confirmation. Use the environment's supported escalation mechanism, keep access scoped to the requested operation, and never reveal, export, copy, or persist credential values. Reauthentication or other changes to authentication state still require explicit user authorization.

## Commands

```bash
swift build                            # Debug build
swift run Dahlia                       # Unsigned debug run
./scripts/run-dev.sh                   # Debug + codesign; preferred for full-feature testing
./scripts/build-app.sh                 # Release .app bundle
swift test --experimental-maximum-parallelization-width 4 # Full test suite; matches CI
swift test --filter SummaryServiceTests # Example targeted suite
CI=true ./scripts/lint.sh              # Check SwiftFormat and SwiftLint without modifying files
```

`swift run Dahlia` is unsigned and cannot use the Data Protection Keychain. Use `./scripts/run-dev.sh` to verify Keychain or Touch ID behavior.

## Definition of Done

- The requested outcome and all applicable repository instructions are satisfied.
- Swift changes pass `swift build`, behavior changes pass targeted tests, and broader changes run `swift test --experimental-maximum-parallelization-width 4` when warranted. Swift source changes also pass `CI=true ./scripts/lint.sh`.
- Confirm from the test summary—not only exit code 0—that the intended tests actually ran.
- Changes to public behavior, settings, or schemas include the corresponding tests, localization, and documentation.
- Review the final diff against the applicable Code Review Rules for unintended changes and regressions.
- If a check cannot run, report the exact command, reason, and next verification step. Do not describe an unverified check as passing.
