import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { openInBrowser } from "../browser.ts";

test("Linux handoff completes while its browser remains running and reports launcher failures", { skip: process.platform === "win32" }, async () => {
  const folder = mkdtempSync(join(tmpdir(), "pi-browser-"));
  const originalPath = process.env.PATH;
  const pidFile = join(folder, "browser.pid");
  let browserPID: number | undefined;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  try {
    process.env.PATH = folder;
    const launcher = join(folder, "gio");
    const url = "https://example.com/approve?one=1&two=2";
    writeFileSync(launcher, `#!${process.execPath}
const { spawn } = require("node:child_process");
const { writeFileSync } = require("node:fs");
if (JSON.stringify(process.argv.slice(2)) !== ${JSON.stringify(JSON.stringify(["open", url]))}) process.exit(2);
const browser = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "inherit" });
browser.unref();
writeFileSync(${JSON.stringify(pidFile)}, String(browser.pid));
process.exit(0);
`, { mode: 0o755 });
    await Promise.race([
      openInBrowser(url, "linux"),
      new Promise<never>((_resolve, reject) => { deadline = setTimeout(() => reject(new Error("Handoff waited for browser exit")), 2000); }),
    ]);
    clearTimeout(deadline);
    browserPID = Number(readFileSync(pidFile, "utf8"));
    assert.ok(browserPID > 0);
    assert.doesNotThrow(() => process.kill(browserPID!, 0));

    writeFileSync(launcher, `#!${process.execPath}\nprocess.exit(2);\n`, { mode: 0o755 });
    await assert.rejects(openInBrowser(url, "linux"), /Browser launcher failed \(2\)/);
    rmSync(launcher);
    await assert.rejects(openInBrowser(url, "linux"), { code: "ENOENT" });
  } finally {
    clearTimeout(deadline);
    // Only stop the fake browser PID captured from the child this test launched.
    if (browserPID === undefined) {
      try { browserPID = Number(readFileSync(pidFile, "utf8")); } catch {}
    }
    if (browserPID) process.kill(browserPID, "SIGTERM");
    if (originalPath === undefined) delete process.env.PATH;
    else process.env.PATH = originalPath;
    rmSync(folder, { recursive: true, force: true });
  }
});
