# Dahlia

[Japanese / 日本語](README_ja.md)

A macOS native real-time transcription app. Captures microphone and system audio simultaneously, transcribes speech on-device, and optionally generates LLM-powered summaries.

## Features

- **Dual Audio Capture** — Record microphone (AVAudioEngine) and system audio (ScreenCaptureKit) at the same time
- **On-Device Transcription** — Real-time speech-to-text using Apple Speech framework
- **LLM Summaries** — Generate structured summaries via OpenAI-compatible API (optional)
- **Project Management** — Organize transcripts into vault/project hierarchy synced with filesystem folders
- **Meeting Detection** — Automatically detect meeting sessions with 3-layer detection
- **Screenshot Capture** — Attach screenshots to transcripts for multimodal summaries
- **Bilingual UI** — Japanese (primary) and English

## Requirements

- macOS 26+
- Swift 6.2
- Xcode 26+ (for Swift toolchain)

Databricks AI Gateway authentication uses OAuth U2M through the Databricks CLI. Install a current CLI release before signing in from Model Settings. Dahlia reads short-lived tokens on demand with `databricks auth token`; it does not store Databricks tokens itself.

## Build & Run

```bash
# Debug build and run (unsigned)
swift build && swift run

# Debug build with code signing (enables Data Protection Keychain + Touch ID)
./scripts/run-dev.sh

# Build release .app bundle
./scripts/build-app.sh && open Dahlia.app

# Run tests
swift test

# Build, sign, notarize, and staple a versioned DMG
./scripts/notarize.sh

# Create the matching GitHub Release and attach the notarized DMG
./scripts/create-github-release.sh

# Format and lint
./scripts/lint.sh
```

> **Note:** `swift run` produces an unsigned binary and cannot use Data Protection Keychain. Use `run-dev.sh` for full functionality.

If you set `SENTRY_DSN` before running `build-app.sh` or `notarize.sh`, the generated release app embeds the DSN into `Info.plist` and enables Sentry when launched from Finder. Debug runs remain disabled, so `swift run` and `run-dev.sh` do not send Sentry events by default.

`build-app.sh` and `run-dev.sh` never upload files externally. When `notarize.sh` builds a Sentry-enabled release, it requires `SENTRY_AUTH_TOKEN` and `sentry-cli`, verifies that the executable and dSYM UUIDs match, then uploads the dSYM after notarization succeeds:

```bash
export SENTRY_DSN="https://<key>@o0.ingest.sentry.io/<project>"
export SENTRY_AUTH_TOKEN="<organization-auth-token>"
brew install getsentry/tools/sentry-cli
```

Only debug symbols are uploaded by default. Source context can expose application source code in Sentry and must be enabled explicitly with `SENTRY_INCLUDE_SOURCES=1`. Keep `SENTRY_AUTH_TOKEN` in `.env.local`, Keychain, or a CI secret; it is never embedded in the app. Keep each release dSYM in a private archive and do not attach it to the public GitHub Release.

The app sends crash stacks and explicitly captured errors, but disables default PII, automatic failed-request capture, network breadcrumbs, performance tracing, screenshots, and source upload. Configure server-side data scrubbing and IP address scrubbing in the Sentry project as an additional safeguard. Captured errors and tags must not include transcripts, audio, calendar details, API payloads, credentials, or user-specific paths.

Before the first notarization run, create a notarytool keychain profile:

```bash
xcrun notarytool store-credentials "dahlia-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`./scripts/notarize.sh` uses `NOTARY_PROFILE` (default: `dahlia-notary`) and produces a signed, notarized, and stapled `Dahlia-<version>.dmg` ready for distribution. The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`.

To publish a release, install and authenticate the GitHub CLI (`gh`), commit and push the version change and all other source changes, then run:

```bash
./scripts/notarize.sh
./scripts/create-github-release.sh
```

`create-github-release.sh` verifies the DMG signature, notarization ticket, filename, and disk image integrity. It then creates `v<version>` at the current commit (or verifies an existing tag points there), creates the corresponding GitHub Release with generated notes, and uploads the DMG. It refuses to publish from a dirty working tree.

## Architecture

```
AudioCaptureManager (microphone / AVAudioEngine)
SystemAudioCaptureManager (system audio / ScreenCaptureKit)
    ↓ onAudioBuffer
AudioSourcePipeline → CapturedAudioChunk
    ↓ AudioFrameRouter (one physical capture per source)
    ├─ BatchAudioFileWriter (lossless recording)
    └─ AudioBufferBridge → SpeechTranscriberService (low-latency transcription)
        ↓ TranscriptionEvent
        ├─ TranscriptStore (real-time state)
        └─ LiveCaptionStore (ephemeral captions)
    ↓ Combine debounce(500ms)
MeetingPersistenceService → SQLite (GRDB)
```

See [Calendar event persistence schema](docs/calendar-event-schema.md) for the UID/RECURRENCE-ID key, source mapping, and Meeting cardinality contract.

### Project Structure

```
Sources/Dahlia/
├── Audio/          # Audio capture (mic & system)
├── Database/       # GRDB models, migrations, repository
├── Models/         # Domain models
├── Services/       # LLM, vault sync, meeting detection, keychain
├── Speech/         # Speech transcription pipeline
├── Utilities/      # Helpers (UUID v7, localization, etc.)
├── ViewModels/     # CaptionViewModel, SidebarViewModel
├── Views/          # SwiftUI views
└── Resources/      # Localized strings, assets
```

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit
- [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) — Crash reporting for release builds

## License

All rights reserved.
