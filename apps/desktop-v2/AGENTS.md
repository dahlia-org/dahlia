# Dahlia Desktop v2 Guide

## Scope

This file applies to `apps/desktop-v2` (`@dahlia-ai/desktop-v2`), a standalone Electron app that records, transcribes on the Mac and summarizes with a Databricks workspace. The repository-root `AGENTS.md` still applies. Read [`README.md`](README.md) for commands and behavior and the [Desktop v2 spec](../../docs/spec/desktop/electron-v2.md) for the decisions. It shares no code, data or identity with Dahlia for macOS (`apps/macos`), the Server, `packages/ui` or the Electron alpha (`apps/desktop`); do not import from them.

## Rules

- Keep `nodeIntegration: false`, `contextIsolation: true`, `sandbox: true` and web security for the window. Expose a preload operation only for an actual need; check its sender and input in the main process with `src/main/policy.ts`, tested in `tests/policy.test.ts`.
- Tokens, authorization codes and callback queries stay in the main process and out of logs and error messages.
- Recording must not wait on sign-in, the network or processing. Never drop audio silently: a write failure stops the recording visibly and keeps what was written. Do not rewrite or truncate a recording file.
- Speech recognition runs only in the `native/` helper process, never in the main process or as a native addon, and the audio never leaves the Mac. A transcript replaces the earlier one only after the whole run succeeds.
- Do not add runtime dependencies without approval; the database is `node:sqlite`. Released databases must never be destroyed: add a migration instead of editing a shipped one in `src/main/db.ts`.
- UI strings go in both languages in `src/renderer/i18n.ts`. Match Dahlia for macOS's look (tokens in `src/renderer/styles.css`); modal cards are in-window, and clicking the backdrop does what Cancel does.

## Validation

```bash
pnpm --filter @dahlia-ai/desktop-v2 check   # lint, types, tests and build
pnpm --filter @dahlia-ai/desktop-v2 build:native
```

Changes to the helper also run it on real audio (see README). Launch the app before reporting runtime behavior as verified, and stop it only by the PID you started.
