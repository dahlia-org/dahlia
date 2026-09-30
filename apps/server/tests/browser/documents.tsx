// pnpm dev:client -> /tests/browser/documents.html. Synthetic in-memory API; no credentials or real data.
import React from "react";
import { createRoot } from "react-dom/client";
import { MeetingNotes } from "../../src/client/Documents";
import { DocumentCore, removedBlocks, type DocumentRecovery } from "../../src/documents/core";
import { encodeId } from "../../src/typeid";
import { uuidV7 } from "../../src/id";
import "../../src/client/styles.css";

const workspace = encodeId("workspace", "019959c4-4000-7000-8000-000000000001");
const meeting = encodeId("meeting", "019959c4-4000-7000-8000-000000000002");
const documentId = encodeId("document", "019959c4-4000-7000-8000-000000000002");
type State = { core: DocumentCore; revision: number; generation: string; initialized: boolean; recoveries: DocumentRecovery[] };
declare global { interface Window { documentFixture: State } }
const client = new URLSearchParams(location.search).get("client");
if (!client) {
  window.documentFixture = { core: new DocumentCore(), revision: 0, generation: uuidV7(), initialized: false, recoveries: [] };
  createRoot(document.getElementById("root")!).render(<main className="p-4"><h1>共同編集・メモリ API fixture</h1><div className="flex gap-4">{["A", "B"].map((id) => <iframe key={id} title={`Editor ${id}`} src={`?client=${id}`} className="h-[700px] w-1/2 border" />)}</div></main>);
} else {
  const state = parent.documentFixture;
  let offline = false;
  const now = () => new Date().toISOString();
  window.fetch = async (input, init) => {
    if (offline) throw new TypeError("Synthetic offline connection");
    const request = new Request(input, init), url = new URL(request.url);
    if (url.pathname.endsWith("/capabilities")) return Response.json({ documents: { version: 1 } });
    if (url.pathname.endsWith("/session")) return Response.json({ user: { id: encodeId("user", client === "A" ? "019959c4-4000-7000-8000-000000000003" : "019959c4-4000-7000-8000-000000000004") } });
    const body: Record<string, unknown> = request.method === "POST" ? await request.json() : {};
    if (url.pathname.endsWith("/presence")) return Response.json({ items: [] });
    if (url.pathname.endsWith("/recoveries")) {
      if (request.method === "POST") state.recoveries.push(body as unknown as DocumentRecovery);
      return Response.json({ items: state.recoveries.map((item) => ({ ...item, createdAt: now() })), nextCursor: null });
    }
    if (url.pathname.endsWith("/sync")) {
      if (body.update) {
        const before = state.core.projection(), checkpoint = state.core.checkpoint();
        state.core.apply(body.update as string); state.core.repairBlockIDs(uuidV7);
        const blocks = removedBlocks(before, state.core.projection());
        if (blocks.length) state.recoveries.push({ id: encodeId("documentRecovery", uuidV7()), blocks, reason: "deleted" });
        if (checkpoint !== state.core.checkpoint()) state.revision++;
      }
      return Response.json({ generation: state.generation, revision: state.revision, update: state.core.difference(body.vector as string) });
    }
    if (request.method === "POST") state.initialized = true;
    return Response.json({ document: state.initialized ? { id: documentId, workspaceId: workspace, meetingId: meeting, schemaVersion: 1,
      generation: state.generation, revision: state.revision, checkpoint: state.core.checkpoint(), text: state.core.projection().text, createdAt: now(), updatedAt: now() } : null });
  };
  // SSE is only an optimization; exercise the real HTTP recovery timer.
  window.EventSource = class { addEventListener() {} close() {} } as unknown as typeof EventSource;
  createRoot(document.getElementById("root")!).render(<main className="p-4"><h2>Editor {client}</h2>
    <label><input type="checkbox" onChange={(event) => { offline = event.currentTarget.checked; }} /> Offline</label>
    <MeetingNotes workspaceId={workspace} meetingId={meeting} editable /></main>);
}
