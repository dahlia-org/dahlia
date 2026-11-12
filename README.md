# Dahlia

[Japanese / 日本語](README_ja.md)

A macOS native real-time transcription app. Captures microphone and system audio simultaneously, transcribes speech on-device, and optionally generates LLM-powered summaries.

## Features

- **Dual Audio Capture** — Record microphone and system audio through ScreenCaptureKit, with speaker echo cancellation for built-in microphones
- **On-Device Transcription** — Real-time speech-to-text using Apple Speech framework
- **Automatic Batch Language Detection** — Detect each recording file's language with WhisperKit, then transcribe it with Apple Speech
- **AI Summaries** — Generate structured summaries through the Pi agent you install (optional; Pi is not bundled)
- **Optional Dahlia Server** — Self-host an authenticated Responses gateway for Dahlia's Pi agent without distributing provider credentials to each user. The official managed offering is Dahlia Cloud.
- **AI Meeting Access** — Explore meeting evidence and optionally reorganize Projects or correct summaries through a workspace-scoped local MCP server
- **Upcoming Events** — Hover over a sidebar event to join its meeting link and start recording, or open its options menu to join the service, schedule automatic recording, or open the event in Calendar. A timer icon marks events with automatic recording enabled. Joining from the main schedule also starts recording.
- **Project Management** — Organize meetings in a database-backed root/subproject workspace hierarchy, with chronological or Project-grouped sidebar views and Workspace-scoped pinned Projects
- **Conversation Analytics (Beta)** — Compare speaking pace, speaking-time balance, conversation occupancy, and overlapping speech from confirmed microphone and system-audio transcripts
- **Meeting Detection** — Combine microphone activity with supported app or meeting-window evidence and offer to start recording
- **Calendar Auto-Recording** — Arm an individual upcoming event from the main window or menu bar to start recording automatically at its scheduled time
- **Meeting Link Apps** — Choose a default app for meeting links and override it for Google Meet, Zoom, Microsoft Teams, or Slack, including an installed Google Meet Chrome app
- **Automatic Meeting-End Stop** — Optionally stop and save after supported meeting audio activity ends; browsers require meeting-window evidence
- **Screenshot Capture** — Attach screenshots to transcripts for multimodal summaries, optionally detecting and saving only shared slides or screens
- **Automatic Updates** — Securely check, download, and install new releases with Sparkle 2
- **Bilingual UI** — Japanese (primary) and English

## Requirements

- macOS 26+
- Apple Silicon (arm64)
- Microphone and Screen Recording permissions (ScreenCaptureKit is used even for microphone-only recording)
- Swift 6.2
- Xcode 26+ (for Swift toolchain)

When upgrading a legacy database, recording sessions whose meeting row is missing are preserved in a new local **Recovered Recordings** workspace. Surviving IDs, transcripts, notes, and images are retained; the original meeting title and workspace cannot be inferred from a session alone. Recovery does not connect this workspace to a server or configure an export folder, and automatic processing is disabled. Missing audio files are not recreated. Other database inconsistencies still stop startup rather than deleting data or bypassing integrity checks.

Setup starts automatically on a new installation and whenever no workspace exists, even if setup was completed before. It prepares a workspace automatically after account selection. The Local and Databricks accounts get a `Default` workspace without an export folder; their existing workspaces are reused. Cloud and Server Accounts use workspaces discovered from the server, preferring workspaces owned by the personal organization regardless of their display name, without creating another workspace. You can continue configuring other settings while discovery runs; setup completes only after a workspace is available and opened. If preparation fails, retry from the completion screen. Manual setup and workspace management remain available in Settings.

Choose how Dahlia runs Pi with **Use Dahlia-managed Pi** in **Settings → Features → Dahlia AI**. When off (the default), Dahlia finds and displays `pi` on PATH, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, or `~/bin`. When on, it displays and uses the Pi installed in Dahlia's Application Support directory; **Install Pi** downloads the official macOS release from GitHub if needed, and **Check for Updates** updates that copy. The choice is saved per account and applies to newly started Pi processes. You cannot enter an executable path manually. Accounts that previously selected Dahlia's `bin/pi` keep that selection; other old paths switch to PATH discovery. Versions live under `Pi/releases/<version>`, and Dahlia keeps the commands it installs in `bin` next to that folder: `bin/pi` is a symlink to the current version, and `bin/pi-update` installs a version. An update keeps the previous version and any version a running Pi uses, and removes the rest. To use that Pi in a terminal, add `export PATH="$HOME/Library/Application Support/Dahlia/bin:$PATH"` to your shell profile. Then set `export PI_SELF_UPDATE_COMMAND="pi-update {version}"` so `pi update` (Pi 1.5.0 or later) updates it; Pi splits this variable on spaces, so it names the command instead of its full path. Do not set the variable when another `pi`, such as one from npm or Homebrew, comes first on your PATH: `pi update` would then install into Dahlia's folder instead of updating that `pi`. Dahlia keeps its Pi state and authentication in its own directory, separate from your `~/.pi` and any Codex installation. In **Settings → Features → Dahlia AI**, the Local Account signs in through the browser to OpenAI (ChatGPT subscription) and Anthropic (Claude Pro/Max), separately or both; its model pickers list both. Each Databricks workspace you connect (by its HTTPS URL, from the account menu's sign-in) is a separate Databricks account, shown with the Databricks logo, the workspace's host name, and your email. A Databricks account uses only that workspace's AI Gateway models and has its own workspaces, kept on this Mac without syncing. Workspaces can move between accounts; disconnecting a Databricks workspace returns its workspaces to the Local Account. Setup and the account menu's sign-in offer a Databricks workspace or the Local Account; Dahlia Cloud and Server sign-in is hidden for now, and existing connections keep working. On this Mac, chat runs inside an Apple Seatbelt sandbox. In **Settings → Features → Dahlia AI → Security**, set the account’s working folder (`~/Dahlia` by default, readable and writable) and add files or folders with read-only or read-and-write access. Folder grants include descendants; file grants cover only that file. Changes and removals apply from the next message; cancel a running response to stop work using the previous permissions. Dahlia’s skills, screenshots, and database remain read only, and its credentials, Pi runtime, and shell startup files remain protected. Other user files are inaccessible without a grant. Network access is allowed, so readable content can be sent externally. The sandbox uses a temporary home; reference added home files by absolute path (for example, set `DESK_CONFIG` for `.desk.toml`). These settings apply only to this Mac’s chat for the current account, including Local and Server Accounts. In **Settings → Features → Dahlia AI**, a Databricks account can turn on its workspace's Unity AI Gateway MCPs (Gmail, Google Calendar, Google Drive, Slack, GitHub, Atlassian, and Microsoft 365) for chat; Dahlia calls them with the account's Databricks access token, and tools that do more than read follow chat's approval mode. ChatGPT sign-ins made with earlier Codex-based versions are not carried over; sign in again. Databricks CLI is not required, and its configuration and token cache are not imported: existing users must enter the workspace URL and sign in again. Dahlia stores Databricks OAuth credentials in the Mac's Keychain and passes access tokens to Pi over its private RPC pipe for each request. ChatGPT and Claude sign-ins stay in Pi's directory under Dahlia's Application Support directory.

Settings are organized by scope. **Features → Dahlia AI** holds the selected account's Pi runtime, providers, models and MCP settings. Its tabs start with **General**, then **Models**. **General** includes account-specific custom instructions for AI chat on this Mac; they apply to new chats and chats closed and reopened, and clearing the field disables them. Summary generation and image analysis do not use them. **Models** groups provider registration and management with each gateway's model switches, followed by Auto review settings. **Summary generation** and **Image analysis** tabs hold generation preferences. The **Packages** tab links to [Pi’s package catalog](https://pi.dev/packages) and installs npm sources (`npm:<package>`) or Git URLs (for example, `https://github.com/mats16/ai-desktools`) into the selected account’s Pi directory. It also lists and uninstalls packages. Only install trusted packages. Skills and prompt templates are available when the next chat process starts; close and reopen an existing chat to apply changes. Package extension code and themes stay disabled, and packages do not affect structured generation or sign-in processes. Package files are read-only inside chat’s sandbox; package commands use this account’s Pi selection and environment settings and respect npm’s configured registry. If that registry provides no available versions, the app explains the failure and keeps the command output under expandable error details. **Features → Meetings** holds the selected account's transcription, live subtitle, screenshot and meeting link settings, including whether live transcription produces the first summary draft and whether recordings are processed automatically when they end. These preferences apply across the account's workspaces on this Mac and are not synced to another Mac or Web. **Features → Workspace** manages workspaces and their shared output language, and **Features → Dahlia MCP** shows how to register Dahlia's MCP server with an AI agent. **This Mac → Data Protection** groups server-content retention, image cache limits, recorded-audio retention and transcription recovery; its **Backups** tab creates, imports and restores Local Account workspace backups. Existing retention values and confirmation before shortening audio retention are preserved.

The sidebar defaults to Meetings; use ⌃1–⌃3 to switch between Meetings, Projects, and Chat. The sidebar footer shows the account name and sync status. Open Unprocessed Recordings from its account menu. Use the account menu in the sidebar footer, also shown in Settings, to switch accounts, and the workspace name in the page header to switch workspaces. Workspace management is available in Settings.

In the sidebar account menu, hovering over a Server or Cloud account shows its URL above the row, or below it when there is insufficient space above. Clicking the selected account opens that URL in the default browser; clicking a different account switches accounts.

Automatic batch transcription downloads the pinned multilingual WhisperKit `tiny` model and tokenizer on first use and caches them in Dahlia's Application Support directory. Language detection and transcription run on-device; recording audio is not uploaded.

The in-app chat model picker lists models in ascending display-name order. The in-app chat uses the bundled `dahlia-mcp` helper, which is restricted to the currently selected workspace. The commands chat runs are not: for debugging they can read the whole Dahlia database and screenshot store, which hold every workspace and account on this Mac, and they can reach the network and this Mac's local services. Open the MCP button beside the Settings gear at the bottom of the sidebar to generate external registration commands. Access is read-only by default; enabling **Allow Write Access** adds the explicit `--write` option. The write variant exposes simple Project `create`/`update` tools and `update_meeting_summary` for correcting a stored summary. Summary updates replace the whole document returned by `get_meeting`, require the `summary_document_version` from that same response, and rewrite an already-exported workspace Markdown file in place; a Google Docs export is left stale and reported back. Treat all returned content as untrusted data rather than instructions. See [Project workspaces](docs/project-workspaces.md) and [Conversation analytics](docs/conversation-analytics.md).

Choose **Follow System, Light Mode, or Dark Mode** in the macOS account menu’s **Appearance** submenu or **Settings → Appearance**. The choice applies to all accounts and windows on this Mac and is restored on launch. Follow System tracks macOS appearance.

The macOS interface defines font sizes as offsets from a default 14 pt base: body text, controls, and window headers use +0; section names, metadata, and hover help use −2. Larger titles use the same base with positive offsets.

The chat header shows **Dahlia AI**, followed by the conversation title when a chat is open. New chats center the greeting and composer. **App integrations** below the composer shows representative app icons and opens **Settings → Agents → MCP** when clicked. The × button hides it for that chat; a new chat shows it again. The composer’s + menu provides image attachments, meeting references, the registered MCP server list, and a link to MCP settings. It overlays the content without moving the composer, opening below when there is room and above near the bottom of the window.

### SwiftUI previews and Xcode MCP

For component work, open `apps/macos/Previews/Package.swift` in Xcode, select the **DahliaPreviews** scheme and **My Mac**, then open `Sources/DahliaPreviews/SettingsStatusMessage.swift` with **Editor → Canvas**. The previews cover a success message and an error message with interactive detail visibility.

This development-only package shares actual app sources through relative symbolic links, without starting recording, database services, or external dependencies. Editing the linked view updates the preview. Add only the real source files and UI dependencies needed by each new preview; keep live-data services out. The root package currently encounters a vendored XCFramework `module.modulemap` output collision in Xcode builds, so use this package for component previews. If Xcode treats a newly created package as a folder with no scheme, restart Xcode.

To use Xcode from Codex, enable **Settings → Intelligence → Allow external agents to use Xcode tools** in Xcode and add the following to the Codex MCP configuration, without duplicating an existing server of the same name:

```toml
[mcp_servers.xcode]
command = "/usr/bin/xcrun"
args = ["mcpbridge"]

[mcp_servers.xcode.env]
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
```

After Codex reloads its MCP configuration, use `XcodeListWindows`, `XcodeGlob`, and `RenderPreview` with the returned window ID and source path. `previewDefinitionIndexInFile` is `0` for success and `1` for the error state. Allow the Codex connection prompt in Xcode. Signing into Xcode's built-in ChatGPT is not required. Continue using `run-dev.sh` to verify recording, Keychain, and whole-window behavior.

## Build & Run

```bash
# Debug build and run (unsigned; chat unavailable without the bundled dahlia-mcp helper)
swift build && swift run Dahlia

# Debug build with code signing (enables Data Protection Keychain)
./scripts/run-dev.sh

# Open the last selected settings category (development profile only)
./scripts/run-dev.sh --settings

# Start with a new development-profile database
./scripts/run-dev.sh --reset

# Copy the production SQLite database into the development profile before launch
./scripts/run-dev.sh --copy-production

# Update the signed app without launching it
./scripts/run-dev.sh --build-only

# Build a release-configuration .app using the development profile
./scripts/build-app.sh

# Run tests
swift test

# Build, sign, notarize, and staple Dahlia.dmg
.agents/skills/release-dahlia-app/scripts/notarize.sh

# After $release-dahlia-app prepares reviewed bilingual notes, create the GitHub Release
.agents/skills/release-dahlia-app/scripts/create-github-release.sh \
  --notes-file-ja .build/release-notes/release-note-ja.md \
  --notes-file-en .build/release-notes/release-note-en.md

# Format and lint
./scripts/lint.sh
```

> **Note:** `swift run Dahlia` has no bundled `dahlia-mcp` helper and cannot use Data Protection Keychain. Use `run-dev.sh` for full functionality. `run-dev.sh` uses a development profile that keeps its database, recording recovery files, Pi state, broker sockets, and process lock separate from the release app. The main checkout uses `~/Library/Application Support/Dahlia-Development`; each linked Git worktree uses its own gitignored `.dahlia` folder, so branches with different migrations never open the same database. `run-dev.sh` stops with an error when the worktree path is too long for that folder's broker socket (103 bytes). `git worktree remove` deletes that folder with the worktree, and `git clean -X` deletes it too. Because it sits inside the worktree, coding agents working there can read it, including data copied by `--copy-production`. The app embeds this choice in its `Info.plist`, and its bundled helpers, including registered MCP commands, read the same file. The launch line `=== Running Dahlia (development profile: …) ===` shows the folder in use. Keychain items and the Databricks connection setting stay shared by all development builds.
> If the login Keychain is locked, `run-dev.sh` asks for the macOS login password before building so the signing certificate's private key is available. The password is read directly by macOS and is not stored by the script. Set `CODESIGN_KEYCHAIN` only when the signing identity is stored in a non-default Keychain.

`run-dev.sh` stores a content-based cache in `.build/run-dev`. With no changes it reuses the signed app; when only the Swift executable changes it retains support assets and re-signs only the app. Changes to support assets or signing configuration, or a missing/modified bundle, trigger a full assembly. Every path verifies the signature before launch. Updating a running development app is refused: finish recording and quit that app before retrying. After initial setup, `--settings` opens the saved settings category; it does not restore meeting selection or unfinished edits.

Use `run-dev.sh` for development builds and launches. `build-app.sh` also embeds the development profile by default, so accidentally launching its release-configuration bundle cannot open the production database. The `--production` option is reserved for the notarization workflow.

`--reset` removes only the selected development profile's `dahlia.sqlite`, `-wal`, and `-shm` files. `--copy-production` (or `--copy`) makes a WAL-safe SQLite backup of the production database, validates it, replaces those same development files, and lets normal app startup run migrations. Production recordings, files, authentication, and settings are not copied; the development profile uses a separate Keychain namespace and starts copied account connections signed out. These options cannot be combined with `--build-only`.

The lint script and pre-commit hook use the exact SwiftFormat version managed by the independent `apps/macos/BuildTools` Swift package. SwiftPM resolves and caches the tool separately from the app's dependencies.

If you set `SENTRY_DSN` before running `build-app.sh`, `notarize.sh`, or `run-dev.sh`, the generated app embeds the DSN into `Info.plist` and enables Sentry. Debug events are tagged with the `debug` environment. `swift run Dahlia` and `run-dev.sh` without an explicitly configured DSN do not send Sentry events.

Set `TELEMETRYDECK_APP_ID` before `build-app.sh`, `notarize.sh`, or `run-dev.sh` to embed the public TelemetryDeck App ID. If it is absent, usage telemetry stays disabled. Debug builds send only Test Mode signals. Dahlia records allowlisted workflow outcomes, bounded recording durations, AI chat adoption, and built-in MCP usage without meeting content or identifiers and never waits for delivery. External MCP client usage is not collected; see [`docs/telemetry.md`](docs/telemetry.md).

`build-app.sh` and `run-dev.sh` never upload files externally. When `notarize.sh` builds a Sentry-enabled release, it requires `SENTRY_AUTH_TOKEN` and `sentry-cli`, verifies that the executable and dSYM UUIDs match, then uploads the dSYM after notarization succeeds:

```bash
export SENTRY_DSN="https://<key>@o0.ingest.sentry.io/<project>"
export SENTRY_AUTH_TOKEN="<organization-auth-token>"
brew install getsentry/tools/sentry-cli
```

Only debug symbols are uploaded by default. Source context can expose application source code in Sentry and must be enabled explicitly with `SENTRY_INCLUDE_SOURCES=1`. Keep `SENTRY_AUTH_TOKEN` in `.env.local`, Keychain, or a CI secret; it is never embedded in the app. Keep each release dSYM in a private archive and do not attach it to the public GitHub Release.

The app sends crash stacks, sanitized technical-error categories, and allowlisted short technical tags, but disables default PII, automatic and network breadcrumbs, failed-request capture, performance tracing, screenshots, and source upload. Configure server-side data scrubbing and IP address scrubbing in the Sentry project as an additional safeguard. Captured diagnostics must not include transcripts, audio, calendar details, API payloads, credentials, free-form errors, or user-specific paths.

Before the first notarization run, create a notarytool keychain profile:

```bash
xcrun notarytool store-credentials "dahlia-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`.agents/skills/release-dahlia-app/scripts/notarize.sh` uses `NOTARY_PROFILE` (default: `dahlia-notary`) and produces a signed, notarized, and stapled `Dahlia.dmg` ready for distribution.

Dahlia uses Sparkle 2 for in-app updates. Production builds check for updates at launch and every hour and show a sidebar badge when one is available; clicking the badge checks the feed again and opens the update dialog for the latest release. Updates are never downloaded or installed automatically. Its Ed25519 private key is stored in the login Keychain under the `com.dahlia.app` account and must be backed up securely. On a new release machine, import the existing private key with Sparkle's `generate_keys` tool; never generate a replacement key or commit the exported private key. `create-github-release.sh` signs the DMG update, appcast, and localized release notes with this key, then uploads `Dahlia.dmg`, `appcast.xml`, `release-note-ja.md`, and `release-note-en.md` to the GitHub Release.

When replacing the release laptop, migrate the Sparkle key as follows. The exported file is an unencrypted private key with the same sensitivity as a password. Export it directly to encrypted offline storage, transfer it through a trusted channel, and never place it in the repository, cloud-synced folders, chat, or issue attachments.

```bash
# Old laptop: export the existing key to encrypted offline storage.
umask 077
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.dahlia.app \
  -x /path/to/encrypted-volume/dahlia-sparkle-private-key

# New laptop: resolve dependencies, then import that same key.
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.dahlia.app \
  -f /path/to/encrypted-volume/dahlia-sparkle-private-key

# Verify that the imported public key matches Resources/Info.plist exactly.
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.dahlia.app \
  -p
# Expected: HR6N/+ImpB4ahCwyYLfF+CKJf2YG267B7pu5Q8CSB2E=
```

After importing, remove any unencrypted transfer copy and retain one access-controlled, encrypted backup. Do not run `generate_keys` without `-f` on the new laptop: creating a different key would prevent installed Dahlia versions from accepting future updates.

To publish a release, install and authenticate the GitHub CLI (`gh`), then use the repository's `$release-dahlia-app` skill in Codex. The skill determines the version from the complete release range, updates both version keys in `Resources/Info.plist`, and writes reviewed Japanese and English notes under `.build/release-notes`. Commit and push the version change and all other source changes before running:

```bash
.agents/skills/release-dahlia-app/scripts/notarize.sh
.agents/skills/release-dahlia-app/scripts/create-github-release.sh \
  --notes-file-ja .build/release-notes/release-note-ja.md \
  --notes-file-en .build/release-notes/release-note-en.md
```

`create-github-release.sh` requires both reviewed note files and performs deterministic validation and publishing only. It verifies the DMG signature, notarization ticket, fixed `Dahlia.dmg` filename, embedded marketing/build versions, monotonic build number, Sparkle feed and signing configuration, disk image integrity, and the signatures and lengths of both localized note assets. It then creates `v<version>` at the current commit (or verifies an existing tag points there), creates the corresponding GitHub Release, and uploads the exact DMG and localized notes signed by the appcast. Sparkle selects the Japanese or English notes from the user's preferred app language. The script refuses to publish from a dirty working tree. The latest release is always available directly from <https://github.com/dahlia-org/dahlia/releases/latest/download/Dahlia.dmg>.

## Product Direction

See [PRODUCT.md](PRODUCT.md) for the product positioning and the tenets that decide what Dahlia builds and refuses:
AI does the organizing work, the company CRM stays the system of record, recordings and transcripts are protected above
everything else, integrations are delegated to external agents over MCP, and the core stays usable standalone.

## Architecture

For documentation by runtime and purpose, start at the [Documentation index](docs/README.md).

See [ARCHITECTURE.md](ARCHITECTURE.md) for the current runtime data flow, target architecture, conformance status,
remediation plan, and UI responsiveness policy. Historical decisions and their supersession relationships are indexed in
[Architecture Decision Records](docs/adr/README.md).

See [Calendar event persistence schema](docs/calendar-event-schema.md) for the UID/RECURRENCE-ID key, source mapping,
and Meeting cardinality contract.

TypeScript packages share the root pnpm workspace (`apps/server`, `apps/desktop`, `packages/ui`); run `pnpm install` once from the
repository root. Run `cd apps/server && pnpm dev` for Dahlia Server, `cd apps/site && pnpm dev` for the public site,
and `pnpm check` from the root for Server and shared UI validation. Dahlia Server
uses `apps/server/.env.local` and defaults to `DAHLIA_DATABASE_TYPE=sqlite` with
`DAHLIA_DATABASE_URL=file:.data/dahlia-auth.sqlite`, so local development does not require PostgreSQL or Docker.
Database selection is independent from the `OPENAI_API_KEY` and `OPENAI_BASE_URL` AI Gateway configuration.

### Project Structure

The planned Electron app will live in `apps/desktop` with the npm package name `@dahlia-ai/desktop`.

```
apps/
├── macos/          # Native macOS app and SwiftPM tests
│   ├── BuildTools/  # Pinned SwiftFormat package
│   ├── scripts/     # Desktop build, signing, and lint implementations
│   ├── Tests/       # SwiftPM tests
│   └── Sources/Dahlia/
│       ├── Audio/          # Audio capture (mic & system)
│       ├── Database/       # GRDB models, migrations, repository
│       ├── Models/         # Domain models
│       ├── Services/       # Pi runtime, workspace sync, meeting detection, keychain
│       ├── Speech/         # Speech transcription pipeline
│       ├── Utilities/      # Helpers (UUID v7, localization, etc.)
│       ├── ViewModels/     # CaptionViewModel, SidebarViewModel
│       ├── Views/          # SwiftUI views
│       └── Resources/      # Localized strings, assets
├── server/         # Optional self-hostable TypeScript AI Gateway and authentication UI
└── site/           # Public static website
```

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit
- [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) — Crash reporting and allowlisted diagnostics
- [TelemetryDeck SwiftSDK](https://github.com/TelemetryDeck/SwiftSDK) — Anonymous, non-blocking usage metrics
- [Sparkle](https://github.com/sparkle-project/Sparkle) — Secure in-app updates
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device language detection for batch transcription
- [libwebp](https://github.com/SDWebImage/libwebp-Xcode) — Lossy WebP screenshot encoding (quality 75), with JPEG fallback on encoding failure

## License

All rights reserved.
