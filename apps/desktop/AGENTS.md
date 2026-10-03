# Dahlia Electron Alpha Guide

## Scope

This file applies to `apps/desktop` (`@dahlia-ai/desktop`), the online-only Electron alpha. The repository-root `AGENTS.md` still applies. Read [`README.md`](README.md) for commands and runtime behavior and [Electron アルファ版](../../docs/adr/desktop/electron-alpha.md) for the decisions. Dahlia for macOS lives in `apps/macos` and is unaffected by this package.

## Rules

- Render only the shared UI from `@dahlia-ai/ui`. Put UI changes there; express host differences as the existing `App` props, never as copied screens or per-screen Electron branches.
- Keep `nodeIntegration: false`, `contextIsolation: true`, `sandbox: true` and web security for every window. Expose a preload operation only for an actual need, validate its sender and input in the main process, and never expose file system, process or arbitrary IPC access.
- Keep the Server cookie in the `persist:server` session used only by the relay and the sign-in window. Do not add CORS, header-trust, token injection or other Server security relaxations, and do not add Server API changes for this package.
- Keep the alpha identity and storage (`com.dahlia.electron-alpha`, `Dahlia Alpha`) separate from the Swift app. Do not substitute Server jobs for Desktop AI or claim offline durability.
- Trust-boundary rules live in `src/main/policy.ts` with tests in `tests/policy.test.ts`; extend both together.

## Validation

```bash
pnpm --filter @dahlia-ai/desktop check
```

Changes to shared UI also run `pnpm --filter @dahlia-ai/ui check` and the Server `pnpm check`. Launch the built app against a development Server before reporting runtime behavior as verified.
