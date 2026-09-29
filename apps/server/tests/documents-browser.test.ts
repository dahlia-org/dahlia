import { afterEach, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { BrowserDocument } from "../src/client/Documents";
import { DocumentCore, documentFragment } from "../src/documents/core";
import { encodeId } from "../src/typeid";
import { uuidV7 } from "../src/id";
import { RequestError } from "../src/client/api";

const api = vi.hoisted(() => ({ getSession: vi.fn(), getDocument: vi.fn(), exchangeDocument: vi.fn(), listDocumentRecoveries: vi.fn(), getDocumentPresence: vi.fn() }));
vi.mock("../src/client/generated-operations", () => ({ apiOperations: api, apiUrls: { getDocumentEvents: () => "/events" } }));
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.clearAllMocks(); });

it.each([false, true])("refreshes a restored document generation without acknowledging rejected edits (pending=%s)", async (pending) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meetingId = uuidV7(), oldGeneration = uuidV7(), generation = uuidV7();
  const initial = { id: encodeId("document", meetingId), meetingId: encodeId("meeting", meetingId), workspaceId: workspace,
    generation: oldGeneration, revision: 9, schemaVersion: 1 as const, checkpoint: server.checkpoint(), text: "seed",
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
    return { generation, revision: 1, update: server.difference(request.body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  const controller = new BrowserDocument(user, workspace, encodeId("meeting", meetingId), {
    id: encodeId("document", meetingId), meetingId: encodeId("meeting", meetingId), workspaceId: workspace,
    generation, revision: 1, schemaVersion: 1, checkpoint: server.checkpoint(), text: "seed", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
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
