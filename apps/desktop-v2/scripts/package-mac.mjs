// Assembles a local "Dahlia v2.app" from the pinned Electron.app, the built output and the transcription helper.
// CODESIGN_IDENTITY picks the signature (default: ad-hoc, for local launch only; no notarization).
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
// Resolving the electron package downloads the pinned binary on first use.
const electronApp = join(dirname(createRequire(import.meta.url)("electron")), "..", "..");
const bundle = join(root, "out", "Dahlia v2.app");
const helper = join(root, "native", ".build", "release", "dahlia-transcribe");
const identity = process.env.CODESIGN_IDENTITY || "-";
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
if (!existsSync(helper)) throw new Error(`Build the helper first: pnpm run build:native (${helper})`);

rmSync(bundle, { recursive: true, force: true });
mkdirSync(dirname(bundle), { recursive: true });
execFileSync("ditto", [electronApp, bundle]);
const contents = join(bundle, "Contents");
const app = join(contents, "Resources", "app");
cpSync(join(root, "dist"), join(app, "dist"), { recursive: true });
writeFileSync(join(app, "package.json"), JSON.stringify({ name: pkg.name, version: pkg.version, type: "module", main: pkg.main }, null, 2));
// Executables belong in Contents/MacOS, not Resources, or signing and notarization break.
cpSync(helper, join(contents, "MacOS", "dahlia-transcribe"));

const plist = join(contents, "Info.plist");
const strings = {
  CFBundleIdentifier: "com.dahlia.desktop-v2",
  CFBundleName: "Dahlia v2",
  CFBundleDisplayName: "Dahlia v2",
  LSMinimumSystemVersion: "26.0",
  NSMicrophoneUsageDescription: "Dahlia v2 records your microphone during meetings and transcribes it on this Mac.",
  // The system audio loopback is a CoreAudio tap; without this key macOS hands Electron a silent track.
  NSAudioCaptureUsageDescription: "Dahlia v2 records the meeting audio your Mac plays and transcribes it on this Mac.",
};
for (const [key, value] of Object.entries(strings)) execFileSync("plutil", ["-replace", key, "-string", value, plist]);

// Electron's nested code first, then the helper with its own identifier and the hardened runtime, then the app again
// to seal the helper.
execFileSync("codesign", ["--force", "--deep", "--sign", identity, bundle]);
execFileSync("codesign", ["--force", "--options", "runtime", "--identifier", "com.dahlia.desktop-v2.transcribe", "--sign", identity, join(contents, "MacOS", "dahlia-transcribe")]);
execFileSync("codesign", ["--force", "--sign", identity, bundle]);
execFileSync("codesign", ["--verify", "--deep", "--strict", bundle]);
console.log(`Packaged ${bundle} (${identity === "-" ? "ad-hoc" : identity})`);
