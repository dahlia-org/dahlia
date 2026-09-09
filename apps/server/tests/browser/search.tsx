// pnpm dev:client -> /tests/browser/search.html. No live backend or credentials.
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";
import { Search } from "../../src/client/Search";
import { refreshData } from "../../src/client/live-data";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const requests: { query: string; vaultId: string }[] = [];
let release: (() => void) | undefined;
let aborted = false;
const image = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#ddd"/></svg>');
window.fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path.endsWith("/projects")) return Response.json({ items: [{ projectId: "p1", path: "Parent / Child" }] });
  if (path === "/api/v1/files/f1") return Response.json({ id: "f1", name: "Image", contentType: "image/png", variants: { thumb_1568: image }, metadata: { caption: "Image preview" } });
  if (!/^\/api\/v1\/vaults\/[^/]+\/search$/.test(path)) throw new Error(`Unexpected URL: ${path}`);
  const inputBody: { query: string } = await request.json();
  const body = { ...inputBody, vaultId: path.split("/")[4]! };
  requests.push(body);
  if (body.query === "slow") {
    await new Promise<void>((resolve) => { release = resolve; request.signal.addEventListener("abort", () => { aborted = true; resolve(); }); });
  }
  return Response.json({ vaultId: body.vaultId,
    meetings: Array.from({ length: 30 }, (_, i) => ({ id: `m${i}`, meetingId: `m${i}`, kind: "meeting", title: `${body.query || "Recent"} ${i}`, date: "2026-09-03T00:00:00Z", snippet: "Summary", projectPath: "Parent / Child" })),
    screenshots: [{ id: "s1", kind: "screenshot", meetingId: "m0", fileId: "f1", title: "Screenshot result", date: "2026-09-03T00:00:00Z", snippet: "OCR" }],
    projects: [{ id: "p1", projectId: "p1", kind: "project", title: "Child", projectPath: "Parent / Child", date: "2026-09-03T00:00:00Z", snippet: "" }],
    limited: { meeting: false, screenshot: false, project: false } });
};
function App() {
  const [vault, setVault] = useState("v1");
  return <><button id="switch" onClick={() => setVault("v2")}>Switch vault</button><Search key={vault} vaultId={vault} /></>;
}
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for UI");
    await new Promise(requestAnimationFrame);
  }
}
function input() { return document.querySelector<HTMLInputElement>('input[type="search"]')!; }
function type(value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input(), value);
  input().dispatchEvent(new Event("input", { bubbles: true }));
}
function key(value: string, target: EventTarget = input(), options: KeyboardEventInit = {}) {
  target.dispatchEvent(new KeyboardEvent("keydown", { key: value, bubbles: true, ...options }));
}
async function run() {
  createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
  await until(() => document.querySelector(".sidebar-search"));
  const opener = document.querySelector<HTMLButtonElement>(".sidebar-search")!;
  assert(opener.getAttribute("aria-label") === "Search" && opener.querySelector("svg") && !opener.textContent, "Search icon is missing its accessible label");
  opener.focus(); opener.click();
  await until(() => document.querySelectorAll(".search-result").length === 8);
  assert(document.activeElement === input(), "Initial focus missing");
  const thumbnail = document.querySelector<HTMLImageElement>(".search-result img")!;
  assert(thumbnail.getAttribute("src") === "/api/v1/files/f1/variants/thumb_480", "Thumbnail route must select bounded variant");
  thumbnail.dispatchEvent(new Event("error"));
  assert(thumbnail.getAttribute("src") === "/api/v1/files/f1/content", "Unavailable variant must fall back to original");
  input().dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true })); type("契約");
  key("k", input(), { ctrlKey: true, isComposing: true });
  await new Promise(requestAnimationFrame);
  assert(document.querySelector("dialog")?.open, "IME shortcut closed search and discarded composition");
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert(!requests.some((r) => r.query === "契約"), "Sent unfinished IME query");
  input().dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
  await until(() => document.querySelector(".search-result strong")?.textContent === "契約 0");
  const scroller = document.querySelector<HTMLElement>(".search-results")!;
  scroller.scrollTop = 180;
  const scroll = scroller.scrollTop;
  const row = document.querySelector(".search-result");
  const before = requests.length;
  refreshData();
  await until(() => requests.length > before && !document.querySelector('[aria-busy="true"]'));
  assert(input().value === "契約" && scroller.scrollTop === scroll && row === document.querySelector(".search-result"), "Refresh reset input, scroll or DOM");
  type("slow"); await until(() => requests.some((r) => r.query === "slow"));
  type("latest"); await until(() => document.querySelector(".search-result strong")?.textContent === "latest 0");
  release?.(); assert(aborted, "Obsolete request not canceled");
  key("ArrowDown"); await until(() => document.querySelector('[data-selected="true"] strong')?.textContent === "latest 1"); key("Enter");
  await until(() => !document.querySelector("dialog"));
  assert(location.pathname === "/meetings/m1", "Arrow/Enter rank navigation failed");
  assert(document.activeElement === opener, "Focus not restored");
  key("k", window, { ctrlKey: true }); await until(() => document.querySelectorAll(".search-result").length === 8);
  key("7", input(), { metaKey: true });
  await until(() => document.querySelector<HTMLImageElement>(".file-preview-image")?.naturalWidth);
  document.querySelector("dialog")!.dispatchEvent(new Event("cancel", { cancelable: true }));
  await until(() => input());
  document.querySelector("dialog")!.dispatchEvent(new Event("cancel", { cancelable: true }));
  await until(() => !document.querySelector("dialog"));
  opener.click(); await until(() => input());
  document.querySelector<HTMLButtonElement>("#switch")!.click();
  await until(() => !document.querySelector("dialog"));
  document.querySelector<HTMLButtonElement>(".sidebar-search")!.click();
  await until(() => requests.at(-1)?.vaultId === "v2");
  assert(input().value === "", "Vault switch retained query");
  document.body.dataset.testResult = "passed";
  console.log("PASS: shared search debounce, IME, cancellation, rank navigation, preview, focus, refresh and vault isolation");
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.body.dataset.testError = String(error); console.error(error); });
