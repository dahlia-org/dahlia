// Trust-boundary checks for what the renderer sends and loads. Tests: tests/policy.test.ts.
import { audioSources, type AudioSource, type Settings } from "../shared/types.js";
import { summaryLanguages } from "./summary.js";

export const appOrigin = "app://dahlia";

/** The renderer's own pages: the bundled app, or the Vite server in development. */
export function isAppUrl(url: string, developmentOrigin?: string) {
  try {
    const { origin, protocol, host } = new URL(url);
    if (protocol === "app:" && host === "dahlia") return true;
    return developmentOrigin !== undefined && origin === developmentOrigin;
  } catch {
    return false;
  }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function id(value: unknown): string {
  if (typeof value !== "string" || !uuid.test(value)) throw new Error("Invalid id");
  return value;
}

export function source(value: unknown): AudioSource {
  if (!audioSources.includes(value as AudioSource)) throw new Error("Invalid source");
  return value as AudioSource;
}

export function meetingName(value: unknown): string {
  const name = typeof value === "string" ? value.trim() : "";
  if (!name || name.length > 200) throw new Error("Invalid name");
  return name;
}

export function workspaceInput(value: unknown): string {
  if (typeof value !== "string" || value.length > 500) throw new Error("Invalid workspace");
  return value;
}

/** Only known settings with plausible values; a locale or model is checked against its list where it is used. */
export function settingsPatch(value: unknown): Partial<Settings> {
  if (typeof value !== "object" || value === null) throw new Error("Invalid settings");
  const patch: Partial<Settings> = {};
  for (const [key, item] of Object.entries(value)) {
    if (typeof item !== "string") throw new Error("Invalid settings");
    if (key === "transcriptionLocale" && /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(item)) patch.transcriptionLocale = item;
    else if (key === "summaryLanguage" && item in summaryLanguages) patch.summaryLanguage = item;
    else if (key === "summaryModel" && /^system\.ai\.claude-[a-z0-9.-]+$/.test(item)) patch.summaryModel = item;
    else throw new Error("Invalid settings");
  }
  return patch;
}

/** A file under the renderer's build directory for an app:// URL path; never outside it. */
export function rendererFile(root: string, pathname: string, join: (...parts: string[]) => string): string {
  const parts = decodeURIComponent(pathname).split("/").filter(Boolean);
  if (parts.some((part) => part === ".." || part.includes("\\"))) return join(root, "index.html");
  const last = parts.at(-1) ?? "";
  // History routes are the single-page app.
  return parts.length && last.includes(".") ? join(root, ...parts) : join(root, "index.html");
}
