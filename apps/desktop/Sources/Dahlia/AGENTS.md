# apps/desktop/Sources/Dahlia Application Guide

This file applies under `apps/desktop/Sources/Dahlia/`. Changes under `Database/` must also follow `Database/AGENTS.md`.

## Reference Routing

- For current ownership and data flow, read [`Runtime Data Flow`](../../../../ARCHITECTURE.md#runtime-data-flow).
- For audio capture, recording, live subtitles, realtime/batch mode combinations, persistence timing, or stop order, read
  [`Audio and Transcription Data Flow`](../../../../docs/architecture/audio-transcription-data-flow.md).
- For recording, transcription, persistence, or queue changes, also read
  [`Reliability Scope`](../../../../ARCHITECTURE.md#reliability-scope) and
  [`Failure and Overload Policy`](../../../../ARCHITECTURE.md#failure-and-overload-policy).
- For UI, view-model, rendering, loading, or interaction work, read
  [`UI and Interaction Responsiveness`](../../../../ARCHITECTURE.md#ui-and-interaction-responsiveness) when the change can affect workload behavior.
- When fixing a documented architecture deviation, follow its target and completion criteria in the
  [`Remediation Plan`](../../../../ARCHITECTURE.md#remediation-plan).
- For a new or reversed architecture decision, start at the [`ADR index`](../../../../docs/adr/README.md) and read only the related records.
- For telemetry, analytics, Sentry, or external diagnostics, read the [`Anonymous Telemetry Collection Policy`](../../../../docs/telemetry.md) before editing code.

## Safety Invariants

- `RecordingSessionController` owns capture, recognition, segmented recording, and batch-scheduling runtime resources.
- The capture callback path stays short, bounded, synchronous, and independent of MainActor. Do not add per-frame `Task` or actor hops.
- Finalized transcripts and translations use the durable persistence lane. UI rendering, observers, previews, and caches must not gate it.
- Audio frames, finalized data, and recording ranges are never silently dropped. Queue overflow or persistence failure must surface as failure.
- `TranscriptStore` is a bounded, reloadable UI projection. Complete-transcript consumers read SQLite off MainActor.
- Normal stop drains capture, recognition, the event pipeline, and persistence in the documented order.
- `CaptionViewModel` owns requests and UI state, not AVFoundation or Speech runtime resources.
- Feature code emits only typed `UsageTelemetryEvent` values. Never import a telemetry SDK outside its adapter, send content/free text/identifiers, or emit from per-frame, token, or segment paths.
- Telemetry is lossy projection work: never await delivery, add an app-owned retry or durable queue, or include it in recording and persistence drain order.

## Concurrency

- Isolate UI-exposed state, view models, stores, and repositories to `@MainActor`.
- Keep small, bounded, in-memory work synchronous. Do not add `async` or an actor only because an API might become expensive later.
- Move database, disk, network, synchronous OS queries, and input-sized decode or parsing work off MainActor through an owned service or worker.
- Actors own long-lived mutable runtimes and ordering. They are not dedicated threads or priority queues; do not serialize unrelated priority classes through one actor.
- User-initiated UI work takes precedence over prefetch and off-screen work. Show acknowledgement or a bounded partial result before waiting for heavy work.
- Cancel obsolete rebuildable UI work and reject stale completion results by identity or generation.
- Avoid new `@unchecked Sendable` conformances. When an Apple framework or delegate boundary requires one, confine it to a small adapter and document the mutable-state isolation in code.
- Use `@preconcurrency import` only at import boundaries that compensate for missing Sendable conformance in Apple frameworks. Do not use it to hide application data races.

Before adding a responsibility that does not fit the documented ownership boundaries, inspect similar components and avoid creating a duplicate coordinator,
store, repository, or global worker.

## Code Review Rules

Apply the safety and concurrency invariants above and the [Code Review Guide](../../../../docs/code-review.md).
Choose update-rate controls by semantics: debounce only when a quiet period is meaningful; use throttle or coalescing
for continuous progress and latest-wins for replaceable projections. Never drop or delay durable ingress to smooth UI updates.

## Implementation Conventions

- Use time-sortable `UUID.v7()` values for new table-row and domain-entity IDs.
- Use macOS semantic text styles directly in SwiftUI (`.title`, `.title2`, `.title3`, `.headline`, `.body`, `.callout`, `.subheadline`,
  `.footnote`, `.caption`, `.caption2`) and `NSFont.preferredFont(forTextStyle:)` in AppKit. Use `.caption2` for badges, tags, and chips.
  Do not introduce Dahlia-specific point-size scales or global font-size settings without explicit product approval; derive numeric sizes only
  when an API requires them.
- Add UI strings as computed properties in `Utilities/L10n.swift`, then add the same key to both `Resources/ja.lproj` and `Resources/en.lproj`. Japanese is the primary localization.
- Settings screens use `Form` with `.formStyle(.grouped)`, `Section`, `LabeledContent`, and standard controls. Do not add custom cards, custom rows, or fixed-width control frames. Use `.toggleStyle(.switch)` for toggles and `.checkbox` for multiple selection.

### Interaction Conventions

- Buttons and button-like controls must provide visible hover feedback. Use the existing button style or control pattern before adding a new one.
- The clickable hit area must match the full area that shows hover feedback, not only the icon or text glyph. For custom SwiftUI buttons,
  put the padded `frame` and `contentShape` inside the `Button` label; see `CodexChatIconButton` and `ScreenshotOverlayControlButton`.
- Present app-owned popup modal cards as an in-window modal overlay rather than a standard SwiftUI `.sheet`. Use a dimming backdrop and
  a centered card, following `ProjectEditorPresentation`, `ProjectDeletionDialog`, and `DahliaServerSignInView`.
- Clicking the backdrop outside an in-window modal card must invoke the same cancellation path as its Cancel or Close action. While an
  operation cannot safely be interrupted, keep both paths consistently disabled until cancellation is safe.

## Verification

- Run tests for the changed layer first. Recording-pipeline changes must cover start, stop, reconfiguration, per-source routing, and batch-persistence boundaries as applicable.
- For UI changes, run a debug build and, when practical, inspect the affected screen in normal, empty, error, and disabled states.
