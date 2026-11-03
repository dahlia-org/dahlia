// pnpm dev:client -> /tests/browser/workspace-memory.html. Mocked HTTP only.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { SaveSharedMemory, WorkspaceMemory } from "@dahlia-ai/ui/screens/WorkspaceMemory";
import "@dahlia-ai/ui/styles.css";
const preview = new URLSearchParams(location.search).has("preview");
Object.defineProperty(navigator, "language", { value: preview ? "ja-JP" : "en-US", configurable: true });
let notesFail = false;
let purges = 0;
let sharedContent: string | undefined;
let notes = [{ id: "note", content: "Follow up on the migration plan next week.", revision: 1, updatedAt: "2026-09-29T00:00:00Z" }];
window.fetch = async (input, init) => {
  const request = new Request(new URL(input instanceof Request ? input.url : input, location.href), init);
  const path = new URL(request.url).pathname;
  if (path.endsWith("/notes") && request.method === "POST") { sharedContent = (await request.json<{ content: string }>()).content; return Response.json({}); }
  if (path.endsWith("/notes")) return notesFail ? Response.json({ error: "failed" }, { status: 503 }) : Response.json({ items: notes, nextCursor: null });
  if (request.method === "DELETE" && path.endsWith("/memory")) { purges++; notes = []; return Response.json({ deleted: true }); }
  throw new Error(`Unexpected request: ${path}`);
};
const root = createRoot(document.getElementById("root")!);
// Commit synchronously so the reset effect runs before the next click.
const mount = (role = "admin", key = role) => flushSync(() => root.render(<div className="mx-auto max-w-3xl p-6"><WorkspaceMemory key={key} workspaceId="team" role={role} /></div>));
const assert: (value: unknown, message: string) => asserts value = (value, message) => { if (!value) throw new Error(message); };
let step = 0;
const until = async (test: () => unknown) => { step++; const end = performance.now() + 5000; while (!test()) { if (performance.now() > end) throw new Error(`UI timed out at wait ${step}`); await new Promise(requestAnimationFrame); } };
const button = (label: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find(b => b.textContent === label);
async function run() {
  mount();
  await until(() => button("Show shared notes"));
  if (preview) return;
  assert(!document.querySelector('[role="switch"]'), "Retired analysis settings are still shown");
  assert(!document.querySelector("details")!.open, "Destructive section is expanded by default");
  notesFail = true; button("Show shared notes")!.click();
  await until(() => document.body.textContent?.includes("Could not load shared notes"));
  notesFail = false; button("Retry")!.click();
  await until(() => document.body.textContent?.includes(notes[0]!.content));
  assert(button("Edit") && button("Delete"), "Admin note actions missing");
  mount("viewer");
  await until(() => button("Show shared notes"));
  button("Show shared notes")!.click();
  await until(() => document.body.textContent?.includes(notes[0]!.content));
  assert(!button("Edit") && !button("Delete") && !button("Erase memories"), "Viewer has write controls");
  mount("admin", "erase");
  await until(() => button("Erase memories"));
  document.querySelector("details")!.open = true;
  button("Erase memories")!.click(); await until(() => document.querySelector("[data-confirm]"));
  assert(purges === 0, "Erased without confirmation");
  (document.querySelector("[data-confirm]") as HTMLButtonElement).click();
  await until(() => Number(purges) === 1 && !document.querySelector('[role="dialog"]'));
  notes = []; mount("editor");
  await until(() => button("Show shared notes")); button("Show shared notes")!.click();
  await until(() => document.body.textContent?.includes("No shared notes yet"));
  assert(!button("Erase memories"), "Editor has admin controls");
  root.render(<SaveSharedMemory key="no-model" workspaceId="team" workspaceName="Team" content="Answer to share" question="Question" model="" />);
  await until(() => button("Share to memory")); button("Share to memory")!.click();
  await until(() => document.querySelector('[role="dialog"] textarea'));
  assert(!button("Generate memory draft"), "Draft generation is available without a selected model");
  assert(document.querySelector<HTMLTextAreaElement>('textarea')!.disabled === false, "Missing model blocks manual editing");
  (document.querySelector("[data-confirm]") as HTMLButtonElement).click();
  await until(() => sharedContent === "Answer to share" && !document.querySelector('[role="dialog"]'));
  root.render(<SaveSharedMemory key="with-model" workspaceId="team" workspaceName="Team" content="Answer to share" question="Question" model="model" />);
  await until(() => button("Share to memory") && !button("Share to memory")!.disabled); button("Share to memory")!.click();
  await until(() => button("Generate memory draft"));
  (document.querySelector("[data-cancel]") as HTMLButtonElement).click();
  await until(() => !document.querySelector('[role="dialog"]'));
  document.getElementById("result")!.textContent = "PASS: model availability and manual sharing, notes failure/retry/empty, viewer/editor boundaries, confirmed purge";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
