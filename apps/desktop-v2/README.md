# Dahlia Desktop v2

`@dahlia-ai/desktop-v2` is a standalone Electron app for macOS 26 that records a meeting, transcribes it on the Mac with Apple Speech, and summarizes it with a Databricks workspace's AI Gateway. It shares nothing with Dahlia for macOS (`apps/macos`), the Server, `packages/ui` or the Electron alpha (`apps/desktop`). Decisions: [Desktop v2 ADR](../../docs/adr/desktop/electron-v2.md). Plan and open items: [Desktop v2 plan](../../docs/plans/2026-11-20-desktop-v2.md).

## Run

From the repository root:

```bash
pnpm install --frozen-lockfile
pnpm --filter @dahlia-ai/desktop-v2 build:native   # Swift helper: native/.build/release/dahlia-transcribe
pnpm --filter @dahlia-ai/desktop-v2 dev            # Vite renderer with HMR, then Electron
pnpm --filter @dahlia-ai/desktop-v2 build && pnpm --filter @dahlia-ai/desktop-v2 start   # Built renderer, no Vite
pnpm --filter @dahlia-ai/desktop-v2 package        # out/Dahlia v2.app; CODESIGN_IDENTITY selects the signature (default ad-hoc)
pnpm --filter @dahlia-ai/desktop-v2 check          # Lint, types, tests and build
```

Recording needs microphone access, and system audio needs macOS's Screen & System Audio Recording permission. macOS gives these permissions to the responsible process: when you run `dev` or `start` from a terminal, the terminal is asked, and system audio may arrive silent. Check permissions and system audio with the packaged app.

To try the helper on real speech:

```bash
say -v Kyoko -o /tmp/a.aiff "本日の会議を始めます" && afconvert /tmp/a.aiff -o /tmp/a.wav -f WAVE -d LEI16@16000 -c 1
python3 -I -c "import wave; w = wave.open('/tmp/a.wav'); open('/tmp/a.pcm', 'wb').write(w.readframes(w.getnframes()))"
apps/desktop-v2/native/.build/release/dahlia-transcribe transcribe --locale ja-JP --sample-rate 16000 /tmp/a.pcm
```

## How it works

- **Sign-in** opens the system browser for the workspace's OAuth (client `databricks-cli`, scope `offline_access all-apis`, PKCE, a callback on the first free port of `localhost:8020`–`8040`, 300 seconds to finish). The email comes from SCIM `Me`. The credential is encrypted with Electron `safeStorage` in `credential.bin`. Only summaries need sign-in; recording, transcription, reading and settings work before signing in and after signing out. Open sign-in from the account menu or a summary action, and close it to return to local work.
- **Recording**: the renderer captures the microphone (`getUserMedia`, echo cancellation on) and the Mac's audio output (`getDisplayMedia` with loopback audio; the screen track is stopped at once). A 16 kHz `AudioContext` and an AudioWorklet turn each into 16-bit mono chunks of about a second. The main process appends them to `recordings/<meeting>/<recording>/{mic,system}.pcm` (headerless) and fsyncs on a 5-second timer. Failed writes, flushes and disconnected inputs stop the recording with a message and keep saved files. Closing the window hides it and recording continues; quitting asks first, then drains capture before closing the files. A crash can lose capture/IPC buffers as well as unflushed writes; there is no guaranteed maximum loss duration. On launch, a recording left open is closed at its file length and transcribed.
- **Transcription** starts after you stop. `dahlia-transcribe` runs once per source in turn and prints JSON Lines (`asset`, `progress`, `segment`, then `done` or `error`). It downloads the speech model for the language the first time it is used, which needs the network. A run that prints nothing for 5 minutes is stopped. Both sources are merged in time order (the microphone first at the same moment), and the recording's transcript is replaced in one transaction only when the run succeeds. Audio is kept until the meeting is deleted.
- **Summary** runs after transcription, or from the Generate Summary button. It calls `{workspace}/ai-gateway/anthropic/v1/messages` with the selected Claude model (default `system.ai.claude-haiku-5-5`) and a forced tool whose schema fixes the JSON: title, description, sections of paragraph / heading / list / checklist blocks with `HH:MM:SS` transcript references, and action items. The transcript goes in as untrusted input. The meeting takes the summary's title unless you renamed it. A failure keeps the previous summary and shows the reason with Retry.
- **Data**: `~/Library/Application Support/dahlia-v2/dahlia-v2.sqlite` (tables `meetings`, `recordings`, `transcript_segments`, `summaries`, `settings`) and `recordings/`. Deleting a meeting removes its rows and audio. Only one instance runs at a time.
- **Settings**: transcription language (the helper's supported locales), summary model (the workspace's `system.ai.claude-*` model services) and summary language.
- **Security**: the window runs with `contextIsolation`, `sandbox` and web security and without Node integration. The preload exposes only the operations in `src/shared/types.ts` (`DahliaAPI`); the main process accepts them only from the window's own page and validates every input. Navigation away from the app and new windows are blocked; links open in the system browser. Only microphone and display capture permissions are granted, to this window.

## Limits

- macOS 26 or later only (Apple Speech `SpeechAnalyzer`).
- The language is chosen in Settings; there is no automatic language detection or speaker identification. Sources label the transcript (Microphone / System Audio).
- With speakers instead of headphones, other participants may also be picked up by the microphone and appear twice.
- No live transcription, subtitles, AI chat, notes, screenshots, calendar, search, projects, MCP, sync or summary history.
- No distribution signing, notarization or auto-update, and no import of data from Dahlia for macOS or the alpha.
