// Pure trust-boundary rules for the main process. Kept free of Electron imports so they are unit tested.
import { isAbsolute, relative, resolve } from "node:path";

export const appOrigin = "app://dahlia";
const loopbackHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);

/** The Server origin the alpha connects to. Plain HTTP is accepted only for loopback development servers. */
export function serverOrigin(value = "http://localhost:5173"): string {
  let url: URL;
  try { url = new URL(value); } catch { throw new Error(`DAHLIA_SERVER_URL is not a URL: ${value}`); }
  if (url.username || url.password) throw new Error("DAHLIA_SERVER_URL must not contain credentials");
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopbackHosts.has(url.hostname))) {
    throw new Error("DAHLIA_SERVER_URL must use https, or http on localhost");
  }
  return url.origin;
}

/** Renderer requests under /api are relayed to the Server; everything else is the bundled renderer. */
export function isServerPath(pathname: string): boolean {
  return pathname.startsWith("/api/");
}

/** Maps an app:// path to a file inside the renderer directory, or undefined for SPA routes and traversal. */
export function rendererFile(root: string, pathname: string): string | undefined {
  let decoded: string;
  try { decoded = decodeURIComponent(pathname); } catch { return undefined; }
  const file = resolve(root, `.${decoded}`);
  const inside = relative(root, file);
  if (!inside || inside.startsWith("..") || isAbsolute(inside)) return undefined;
  return file;
}

/** Only the bundled renderer may call the relay; other origins (including the sign-in window's pages) are rejected. */
export function relayAllowed(origin: string | null): boolean {
  return origin === null || origin === appOrigin;
}

/** Sign-in completes when the Server navigates back to an application page on its own origin. */
export function signInCompleted(url: string, server: string): boolean {
  let parsed: URL;
  try { parsed = new URL(url); } catch { return false; }
  return parsed.origin === server && parsed.pathname !== "/sign-in" && parsed.pathname !== "/oauth/consent"
    && !parsed.pathname.startsWith("/api/");
}

/** In-app callback after sign-in; anything else falls back to the dashboard. */
export function callbackPath(value: unknown): string {
  return typeof value === "string" && value.startsWith("/") && !value.startsWith("//") && !value.includes("\\") && value.length <= 2048
    ? value : "/dashboard";
}

/** Links leaving the app open in the system browser; app:// links map to the Server's Web URL. */
export function externalURL(url: string, server: string): string | undefined {
  let parsed: URL;
  try { parsed = new URL(url); } catch { return undefined; }
  // Node's URL reports a null origin for app:, so compare its parts.
  if (parsed.protocol === "app:" && parsed.host === "dahlia") return new URL(`${parsed.pathname}${parsed.search}${parsed.hash}`, server).href;
  return parsed.protocol === "https:" || parsed.protocol === "http:" || parsed.protocol === "mailto:" ? parsed.href : undefined;
}
