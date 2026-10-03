// Assembles a local, unsigned-for-distribution "Dahlia Alpha.app" from the pinned Electron.app and the built output.
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
// Resolving the electron package downloads the pinned binary on first use.
const electronApp = join(dirname(createRequire(import.meta.url)("electron")), "..", "..");
const bundle = join(root, "out", "Dahlia Alpha.app");
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));

rmSync(bundle, { recursive: true, force: true });
mkdirSync(dirname(bundle), { recursive: true });
execFileSync("ditto", [electronApp, bundle]);
const app = join(bundle, "Contents", "Resources", "app");
cpSync(join(root, "dist"), join(app, "dist"), { recursive: true });
writeFileSync(join(app, "package.json"), JSON.stringify({ name: pkg.name, version: pkg.version, type: "module", main: pkg.main }, null, 2));
const plist = join(bundle, "Contents", "Info.plist");
for (const [key, value] of [["CFBundleIdentifier", "com.dahlia.electron-alpha"], ["CFBundleName", "Dahlia Alpha"], ["CFBundleDisplayName", "Dahlia Alpha"]]) {
  execFileSync("plutil", ["-replace", key, "-string", value, plist]);
}
// Ad-hoc signature for local launch only; distribution signing and notarization are out of scope for the alpha.
execFileSync("codesign", ["--force", "--deep", "--sign", "-", bundle]);
console.log(`Packaged ${bundle}`);
