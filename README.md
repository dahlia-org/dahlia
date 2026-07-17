# Dahlia

[Japanese / 日本語](README_ja.md)

A macOS native real-time transcription app. Captures microphone and system audio simultaneously, transcribes speech on-device, and optionally generates LLM-powered summaries.

## Features

- **Dual Audio Capture** — Record microphone (AVAudioEngine) and system audio (ScreenCaptureKit) at the same time
- **On-Device Transcription** — Real-time speech-to-text using Apple Speech framework
- **Codex Summaries** — Generate structured summaries through the bundled Codex app-server (optional)
- **AI Meeting Access** — Query summaries and confirmed original transcripts through a vault-scoped, read-only local MCP server
- **Project Management** — Organize transcripts into vault/project hierarchy synced with filesystem folders
- **Meeting Detection** — Automatically detect meeting sessions with 3-layer detection
- **Screenshot Capture** — Attach screenshots to transcripts for multimodal summaries
- **Bilingual UI** — Japanese (primary) and English

## Requirements

- macOS 26+
- Apple Silicon (arm64)
- Swift 6.2
- Xcode 26+ (for Swift toolchain)

Dahlia keeps its bundled Codex state and authentication separate from other Codex apps and the Codex CLI. In **Settings → AI Connection**, choose either a ChatGPT Subscription or an OAuth profile created by `databricks auth login`. The ChatGPT login is stored under Dahlia's Application Support directory; Databricks tokens remain managed by Databricks CLI.

The in-app chat uses the bundled `dahlia-mcp` helper and is restricted to the currently selected vault. To give Claude Code or Codex CLI the same read-only access, open **Settings → Meeting Data Access** and copy the registration command. The command includes both the signed helper path and `--vault-id <UUID>`; rerun it after choosing another vault. The MCP tools expose compact meeting search, stored Markdown summaries, and paginated confirmed original transcript segments. They do not expose notes, screenshots, audio, translated text, or unconfirmed text.

## Build & Run

```bash
# Debug build and run (unsigned; bundled Codex summaries unavailable)
swift build && swift run Dahlia

# Debug build with code signing (enables Data Protection Keychain)
./scripts/run-dev.sh

# Build release .app bundle
./scripts/build-app.sh && open Dahlia.app

# Run tests
swift test

# Build, sign, notarize, and staple Dahlia.dmg
./scripts/notarize.sh

# Generate human-friendly notes with AI and create the matching GitHub Release
./scripts/create-github-release.sh

# Format and lint
./scripts/lint.sh
```

> **Note:** `swift run Dahlia` has no bundled Codex helper and cannot use Data Protection Keychain. Use `run-dev.sh` for full functionality. `run-dev.sh` uses the shared development profile at `~/Library/Application Support/Dahlia-Development`, keeping its database, recording recovery files, Codex state, and process lock separate from the release app. Development builds started by `run-dev.sh` share this profile with each other. On their first run, the app-bundle scripts download the pinned official Codex 0.144.4 GitHub Release for `aarch64-apple-darwin`, verify its SHA-256, and cache it under `.build`.

The lint script and pre-commit hook use the exact SwiftFormat version managed by the independent `BuildTools` Swift package. SwiftPM resolves and caches the tool separately from the app's dependencies.

If you set `SENTRY_DSN` before running `build-app.sh` or `notarize.sh`, the generated release app embeds the DSN into `Info.plist` and enables Sentry when launched from Finder. Debug runs remain disabled, so `swift run Dahlia` and `run-dev.sh` do not send Sentry events by default.

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

`./scripts/notarize.sh` uses `NOTARY_PROFILE` (default: `dahlia-notary`) and produces a signed, notarized, and stapled `Dahlia.dmg` ready for distribution.

To publish a release, install and authenticate the GitHub CLI (`gh`), commit and push the version change and all other source changes, then run:

```bash
./scripts/notarize.sh
./scripts/create-github-release.sh
```

`create-github-release.sh` verifies the DMG signature, notarization ticket, fixed `Dahlia.dmg` filename, embedded app version, and disk image integrity. It then asks Codex to use the repository's `$generate-release-notes` skill to interpret the changes since the previous release and write concise, user-focused notes. The Codex subprocess runs outside the sandbox so it can use local authentication, but ignores personal configuration, disables live web search, requires approval for untrusted commands, and limits its task to read-only investigation and Markdown output. The script also verifies that the DMG checksum did not change during AI generation. Finally, it creates `v<version>` at the current commit (or verifies an existing tag points there), creates the corresponding GitHub Release, and uploads the DMG. It requires an authenticated Codex CLI by default; pass `--notes-file <path>` to publish reviewed Markdown instead. It refuses to publish from a dirty working tree. The latest release is always available directly from <https://github.com/mats16/dahlia/releases/latest/download/Dahlia.dmg>.

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
├── Services/       # Codex app-server, vault sync, meeting detection, keychain
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
