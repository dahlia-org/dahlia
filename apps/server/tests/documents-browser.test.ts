import { afterEach, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { BrowserDocument } from "../src/client/Documents";
import { DocumentCore, documentFragment } from "../src/documents/core";
import { encodeId } from "../src/typeid";
import { uuidV7 } from "../src/id";
import { RequestError } from "../src/client/api";

const api = vi.hoisted(() => ({ getSession: vi.fn(), getDocument: vi.fn(), getMeetingNotes: vi.fn(), initializeMeetingNotes: vi.fn(), exchangeDocument: vi.fn(), listDocumentRecoveries: vi.fn(), getDocumentPresence: vi.fn() }));
vi.mock("../src/client/generated-operations", () => ({ apiOperations: api, apiUrls: { getDocumentEvents: () => "/events" } }));
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.clearAllMocks(); });

it.each([false, true])("refreshes a restored document generation without acknowledging rejected edits (pending=%s)", async (pending) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meetingId = uuidV7(), oldGeneration = uuidV7(), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", meetingId), workspaceId: workspace,
    kind: "notes" as const, title: "", generation: oldGeneration, revision: 9, schemaVersion: 1 as const, checkpoint: server.checkpoint(), text: "seed",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  api.getSession.mockResolvedValue({ user: { id: user } });
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { generation: string; update?: string; vector: string } }) => {
    if (body.generation !== generation) throw new RequestError("document_generation_changed", 409);
    if (body.update) server.apply(body.update);
    return { generation, revision: 2, update: server.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  const controller = new BrowserDocument(user, workspace, initial.meetingId, initial);
  controller.listeners.add(() => {});
  const edit = async (value: string) => {
    const vector = Y.encodeStateVector(controller.editorDocument);
    const text = (controller.editorDocument.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText;
    text.insert(text.length, value);
    await controller.editFromEditor(Y.encodeStateAsUpdate(controller.editorDocument, vector));
  };
  try {
    if (pending) await edit(" pending");
    api.getDocument.mockRejectedValueOnce(new RequestError("document_unavailable", 404));
    await expect(controller.sync()).rejects.toThrow("document_unavailable");
    expect(controller.session.generation).toBe(oldGeneration);
    expect(controller.copyText()).toBe(pending ? "seed pending" : "seed");
    api.getDocument.mockImplementationOnce(async () => {
      if (pending) await edit(" during refresh");
      return { document: { ...initial, generation, revision: 1 } };
    });
    await controller.sync();
    expect(controller.session.generation).toBe(generation);
    expect(controller.session.revision).toBe(1);
    expect(controller.hasUnsent()).toBe(pending);
    expect(server.projection().text).toBe("seed");
    await controller.flush();
    expect(controller.hasUnsent()).toBe(false);
    expect(server.projection().text).toBe(pending ? "seed pending during refresh" : "seed");
  } finally { controller.stop(); server.destroy(); }
});

it("retains a rejected browser draft across detach/sync and merges corrective edits before flushing", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meetingId = uuidV7(), generation = uuidV7();
  api.getSession.mockResolvedValue({ user: { id: user } });
  api.exchangeDocument.mockImplementation(async (request: { body: { update?: string; vector: string } }) => {
    if (request.body.update) server.apply(request.body.update);
    return { kind: "notes" as const, title: "", generation, revision: 1, update: server.difference(request.body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  const controller = new BrowserDocument(user, workspace, encodeId("meeting", meetingId), {
    id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", meetingId), workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 1, schemaVersion: 1, checkpoint: server.checkpoint(), text: "seed", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
  });
  const replace = (value: string) => {
    let update: Uint8Array = new Uint8Array();
    const listener = (bytes: Uint8Array) => { update = bytes; };
    controller.editorDocument.on("update", listener);
    const text = (controller.editorDocument.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText;
    controller.editorDocument.transact(() => { text.delete(0, text.length); text.insert(0, value); });
    controller.editorDocument.off("update", listener);
    return update;
  };
  try {
    const rejected = "x".repeat(2_000_001);
    await expect(controller.editFromEditor(replace(rejected))).rejects.toThrow("document_too_large");
    controller.releaseIfIdle(); // The detached tab must retain the only edited copy.
    await controller.sync();
    expect(controller.hasUnsent()).toBe(true);
    expect(controller.copyText()).toBe(rejected);
    expect(controller.error).toContain("document_too_large");
    await expect(controller.flush()).rejects.toThrow("document_too_large");
    expect(server.projection().text).toBe("seed");
    await controller.editFromEditor(replace("corrected"));
    await controller.flush();
    expect(controller.hasUnsent()).toBe(false);
    expect(server.projection().text).toBe("corrected");
  } finally { controller.stop(); server.destroy(); }
});

it("uses the canonical Notes ID after an offline first edit loses the initialization race", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const userId = encodeId("user", uuidV7()), workspaceId = encodeId("workspace", uuidV7());
  const meetingId = encodeId("meeting", uuidV7()), canonical = encodeId("document", uuidV7()), generation = uuidV7();
  const server = new DocumentCore(), edited = new DocumentCore(); edited.insertText("offline input", uuidV7);
  const controller = new BrowserDocument(userId, workspaceId, meetingId, null);
  controller.listeners.add(() => {});
  const proposed = controller.params.path.documentId;
  expect(proposed).not.toBe(canonical);
  api.getSession.mockResolvedValue({ user: { id: userId } });
  api.initializeMeetingNotes.mockResolvedValue({ document: { id: canonical, generation } });
  api.exchangeDocument.mockImplementation(async ({ params, body }: { params: { path: { documentId: string } }; body: { vector: string; update?: string } }) => {
    expect(params.path.documentId).toBe(canonical);
    if (body.update) server.apply(body.update);
    return { generation, revision: 1, update: server.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  try {
    const update = Y.encodeStateAsUpdate(edited.document);
    Y.applyUpdate(controller.editorDocument, update, "remote");
    await controller.editFromEditor(update);
    await controller.flush();
    expect(api.initializeMeetingNotes).toHaveBeenCalledWith({ params: { path: { workspaceId, meetingId } }, body: { id: proposed } }, false);
    expect(controller.params.path.documentId).toBe(canonical);
    expect(server.projection().text).toBe("offline input");
    expect(controller.hasUnsent()).toBe(false);
  } finally { controller.stop(); server.destroy(); edited.destroy(); }
});

// Allow shared CI workers time for the repeated multi-MiB merges in this full lifecycle test.
it.each(["accumulated", "single"])("keeps the accepted state valid and syncs a correction after an oversized %s rich-text edit", async (mode) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const userId = encodeId("user", uuidV7()), workspaceId = encodeId("workspace", uuidV7());
  const meetingId = encodeId("meeting", uuidV7()), generation = uuidV7();
  const controller = new BrowserDocument(userId, workspaceId, meetingId, {
    id: encodeId("document", uuidV7()), meetingId, workspaceId, kind: "notes", title: "", generation,
    revision: 1, schemaVersion: 1, checkpoint: server.checkpoint(), text: "seed", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
  });
  controller.listeners.add(() => {});
  api.getSession.mockResolvedValue({ user: { id: userId } });
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { update?: string; vector: string } }) => {
    if (body.update) server.apply(body.update);
    return { generation, revision: 2, update: server.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  const fragment = controller.editorDocument.getXmlFragment(documentFragment);
  // The real collaborative editor keeps deleted structs in its Undo history.
  const undo = new Y.UndoManager(fragment, { captureTimeout: 0 });
  const edit = (work: () => void) => {
    let update: Uint8Array = new Uint8Array();
    const listener = (bytes: Uint8Array) => { update = bytes; };
    controller.editorDocument.on("update", listener);
    controller.editorDocument.transact(work);
    controller.editorDocument.off("update", listener);
    return controller.editFromEditor(update);
  };
  const appendRichText = (bytes: number) => edit(() => {
    const paragraph = new Y.XmlElement("paragraph"), text = new Y.XmlText();
    paragraph.setAttribute("id", uuidV7());
    text.insert(0, "linked", { link: { href: `https://example.invalid/${"x".repeat(bytes)}` } });
    paragraph.insert(0, [text]); fragment.insert(fragment.length, [paragraph]);
  });
  try {
    if (mode === "accumulated") { await appendRichText(4 * 1024 * 1024); await controller.flush(); }
    const accepted = controller.session.core.checkpoint(), acceptedText = server.projection().text;
    await expect(appendRichText((mode === "single" ? 8 : 4) * 1024 * 1024)).rejects.toThrow();
    expect(controller.session.core.checkpoint()).toBe(accepted);
    expect(controller.pending).toHaveLength(0);
    controller.releaseIfIdle();
    await controller.sync();
    expect(controller.copyText()).toBe(`${acceptedText}\nlinked`);
    expect(server.projection().text).toBe(acceptedText);
    await expect(controller.flush()).rejects.toThrow();
    await edit(() => {
      fragment.delete(fragment.length - 1, 1);
      const text = (fragment.get(0) as Y.XmlElement).get(0) as Y.XmlText;
      text.insert(text.length, " corrected");
    });
    await controller.flush();
    expect(controller.hasUnsent()).toBe(false);
    expect(server.projection().text).toBe(acceptedText.replace("seed", "seed corrected"));
    expect(server.document.store.pendingStructs).toBeNull();
  } finally { undo.destroy(); controller.stop(); server.destroy(); }
}, 30_000);
