import { spawn } from "node:child_process";

export function browserCommand(url: string, platform = process.platform): [string, string[]] {
  if (platform === "darwin") return ["open", [url]];
  // Pass the URL to the handler directly: cmd's `start` parses URL characters as shell syntax.
  if (platform === "win32") return ["rundll32.exe", ["url.dll,FileProtocolHandler", url]];
  // GIO reports the URI handoff; xdg-open may wait for the browser itself to exit.
  return ["gio", ["open", url]];
}

export function openInBrowser(url: string, platform = process.platform) {
  const [command, args] = browserCommand(url, platform);
  return new Promise<void>((resolve, reject) => {
    // A browser inheriting launcher pipes must not keep the handoff pending.
    const child = spawn(command, args, { stdio: "ignore" });
    child.once("error", reject);
    child.once("exit", (code, signal) => code === 0 ? resolve() : reject(new Error(`Browser launcher failed (${signal ?? code}).`)));
  });
}
