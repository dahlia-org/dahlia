# Dahlia Desktop (Electron alpha)

`@dahlia-ai/desktop` is an online-only development alpha for macOS. It renders the shared Web UI from `@dahlia-ai/ui` in Electron and connects to a Dahlia Server with the existing account session. It does not record, transcribe, run AI on the device, store data offline, or replace Dahlia for macOS (`apps/macos`). Design decisions: [Electron アルファ版](../../docs/adr/desktop/electron-alpha.md).

## Run

Start a Dahlia Server first ([local Node setup](../server/README.md#local-node-deployment)). From the repository root:

```bash
pnpm install --frozen-lockfile
DAHLIA_SERVER_URL=http://localhost:5173 pnpm --filter @dahlia-ai/desktop dev      # Vite renderer with HMR, then Electron
pnpm --filter @dahlia-ai/desktop build                                            # Renderer, main and preload into dist/
DAHLIA_SERVER_URL=http://localhost:5173 pnpm --filter @dahlia-ai/desktop start    # Built renderer, no Vite
pnpm --filter @dahlia-ai/desktop package                                          # out/Dahlia Alpha.app (local, ad-hoc signed)
open "apps/desktop/out/Dahlia Alpha.app" --env DAHLIA_SERVER_URL=http://localhost:5173
pnpm --filter @dahlia-ai/desktop check                                            # Lint, types, tests and build
```

`DAHLIA_SERVER_URL` (default `http://localhost:5173`) must be the Server's public origin, its `DAHLIA_APP_URL`; session cookies and the Server's origin checks are bound to it. Use `https`, or plain `http` only on `localhost`, `127.0.0.1` or `[::1]`. The Electron binary (pinned `electron` 44.4.5) downloads on first launch.

## How it works

- The window loads the bundled renderer from `app://dahlia`. History routes (`/dashboard`, `/o/{id}`) are served as the single-page app; in development the main process forwards renderer requests to the Vite server instead.
- Renderer requests to `app://dahlia/api/**` stay same-origin and the main process relays them to the Server with a separate `persist:server` session. The Server session cookie lives only there; the renderer cannot read it, and pages loaded during sign-in cannot reach `app://`. Requests carrying another `Origin` are rejected. Mutations are sent with the Server origin, as the same-origin Web client does, and the Server still enforces its session, origin and authorization checks. An unreachable Server fails the request exactly as an offline browser does; nothing is reported as saved. Closing an event stream or aborting a request in the renderer also aborts the relayed Server request.
- Sign-in opens the Server's own `/sign-in` page in an isolated window that uses the `persist:server` session. When the Server navigates back to an application page on its origin, the window closes and the app opens the requested page. Sign-out clears the Server session and returns to the sign-in screen; expiry (401) does the same.
- The renderer runs with `contextIsolation`, `sandbox` and web security enabled and without Node integration. The preload exposes only `config()` and `signIn(next)`; the main process accepts them only from the main window's `app://dahlia` frame and validates the callback path. Navigation away from `app://`, new windows and `<webview>` are blocked; `http(s)` and `mailto` links open in the system browser, and `app://` links open the Server's Web URL there. Permissions other than clipboard writing are denied. The renderer sends a Content Security Policy.
- Notes keep unsent edits in memory, as on the Web. Closing or reloading with unsent edits asks for confirmation (Stay is the default); leaving discards them.
- The app is `com.dahlia.electron-alpha` named "Dahlia Alpha" with its data in `~/Library/Application Support/Dahlia Alpha`, separate from Dahlia for macOS (`com.dahlia.app`). Only one instance runs at a time.

## Alpha limits

- Online only: no local database, offline editing or durable unsent Notes.
- Server AI chat, summary regeneration and Server summary settings are hidden, because Desktop AI runs on the device and is not implemented here. Recording, transcription, the menu bar and meeting participation are not included.
- Google may refuse sign-in inside embedded windows; the alpha has no system-browser hand-off yet.
- No distribution signing, notarization, auto-update, or migration of existing user data.
- In `dev`, opening Notes fails with `document_editor_already_attached` under React Strict Mode. The same pre-existing issue affects the Web dev server; production builds are unaffected.
