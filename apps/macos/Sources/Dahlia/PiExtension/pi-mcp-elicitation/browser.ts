import { execFile } from "node:child_process";

export function browserCommand(url: string, platform = process.platform): [string, string[]] {
  if (platform === "darwin") return ["open", [url]];
  // Pass the URL to the handler directly: cmd's `start` parses URL characters as shell syntax.
  if (platform === "win32") return ["rundll32.exe", ["url.dll,FileProtocolHandler", url]];
  return ["xdg-open", [url]];
}

export function openInBrowser(url: string) {
  const [command, args] = browserCommand(url);
  return new Promise<void>((resolve, reject) => {
    execFile(command, args, (error) => error ? reject(error) : resolve());
  });
}
