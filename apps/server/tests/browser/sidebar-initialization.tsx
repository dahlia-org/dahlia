// Open /tests/browser/sidebar-initialization.html under pnpm dev:client. All requests are mocked.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { SidebarProvider, useSidebar } from "../../src/client/Sidebar";

let resolveOrganizations: (response: Response) => void;
window.fetch = () => new Promise<Response>((resolve) => { resolveOrganizations = resolve; });
sessionStorage.removeItem("dahlia:sidebar:sidebar-regression:organization");
function Draft() {
  const [draft, setDraft] = useState("");
  const sidebar = useSidebar();
  return <><output>{sidebar.organizationId}</output><input value={draft} onChange={(event) => setDraft(event.target.value)} />
    <button onClick={() => sidebar.select("team-id")}>Switch organization</button></>;
}
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw Error("Timed out waiting for sidebar");
    await new Promise(requestAnimationFrame);
  }
}
async function run() {
  createRoot(document.getElementById("root")!).render(<SidebarProvider session={{ user: { id: "sidebar-regression" },
     capabilities: { sessions: true, sharing: true, sync: false, admin: false } }}><Draft /></SidebarProvider>);
  await until(() => document.querySelector("input") && resolveOrganizations);
  const input = document.querySelector("input")!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "Unsaved draft");
  input.dispatchEvent(new Event("input", { bubbles: true }));
  resolveOrganizations!(Response.json([{ id: "personal-id", kind: "personal" }, { id: "team-id", kind: "team" }]));
  await until(() => document.querySelector("output")?.textContent === "personal-id");
  if (document.querySelector("input")?.value !== "Unsaved draft") throw Error("Initial organization resolution discarded the draft");
  document.querySelector("button")!.click();
  await until(() => document.querySelector("output")?.textContent === "team-id");
  if (document.querySelector("input")?.value !== "") throw Error("Organization switch retained the previous scope draft");
  document.body.dataset.result = "PASS";
  document.body.append("PASS");
}
void run().catch((error: unknown) => { document.body.dataset.result = "FAIL"; document.body.append(String(error)); });
