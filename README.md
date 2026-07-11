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

# Build, notarize, staple, and repack release archive
./scripts/notarize.sh

# Format and lint
./scripts/lint.sh
```

> **Note:** `swift run` produces an unsigned binary and cannot use Data Protection Keychain. Use `run-dev.sh` for full functionality.

If you set `SENTRY_DSN` before running `build-app.sh` or `notarize.sh`, the generated release app embeds the DSN into `Info.plist` and enables Sentry when launched from Finder. Debug runs remain disabled, so `swift run` and `run-dev.sh` do not send Sentry events by default.

If you use Sentry for app builds, `run-dev.sh` and `build-app.sh` will also try to upload `Dahlia.dSYM` when `SENTRY_AUTH_TOKEN` is set. Install `sentry-cli` first, for example:

```bash
export SENTRY_DSN="https://<key>@o0.ingest.sentry.io/<project>"
brew install getsentry/tools/sentry-cli
```

Before the first notarization run, create a notarytool keychain profile:

```bash
xcrun notarytool store-credentials "dahlia-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`./scripts/notarize.sh` uses `NOTARY_PROFILE` (default: `dahlia-notary`) and produces a stapled `Dahlia.zip` ready for distribution.

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
