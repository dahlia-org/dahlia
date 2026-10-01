import oldFixture from "./fixtures/documents-v1.json";
import { SyncNotifications } from "../src/client/sync-notifications";
import { afterEach, expect, it, vi } from "vitest";
import { Editor } from "@tiptap/core";
import * as Y from "yjs";
import { BrowserDocument } from "../src/client/Documents";
import { DocumentCore, type DocumentRecovery } from "../src/documents/core";
import { firstText, deleteFirst } from "./fixtures/document-helpers";
import { encodeId } from "../src/typeid";
import { uuidV7 } from "../src/id";
import { RequestError } from "../src/client/api";
import { documentEditorOptions } from "../src/documents/editor";

const api = vi.hoisted(() => ({ getSession: vi.fn(), getDocument: vi.fn(), getMeetingNotes: vi.fn(), initializeMeetingNotes: vi.fn(), exchangeDocument: vi.fn(), listDocumentRecoveries: vi.fn(), getDocumentPresence: vi.fn(), saveDocumentRecovery: vi.fn() }));
vi.mock("../src/client/generated-operations", () => ({ apiOperations: api, apiUrls: { getEvents: () => "/events" } }));
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.clearAllMocks(); });

it("retains post-purge IME recovery across editor detach and failed upload", async () => {
  vi.useFakeTimers();
  const server = new DocumentCore(); server.insertText("日本語\ntail", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", uuidV7()), workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 0, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "日本語\ntail",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  api.getSession.mockResolvedValue({ user: { id: user } });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  api.saveDocumentRecovery.mockRejectedValue(new Error("recovery offline"));
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { update?: string; vector: string } }) => {
    if (body.update) server.apply(body.update);
    return { generation, revision: 1, update: server.difference(body.vector) };
  });
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const controller = new BrowserDocument(user, workspace, initial.meetingId, initial);
  const release = controller.retainView();
  // A headless Editor must be created without a browser global (no DOM is needed).
  vi.unstubAllGlobals();
  const editor = new Editor({ ...documentEditorOptions(controller.editorDocument, true, "", undefined, controller.preserveEditorRecovery), element: null });
  editor.view.updateState(editor.state.reconfigure({ plugins: editor.extensionManager.plugins }));
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  editor.commands.setTextSelection(2);
  const view = editor.view;
  const composing = vi.spyOn(editor, "view", "get").mockReturnValue(new Proxy(view, { get: (target, key): unknown => key === "composing" ? true : Reflect.get(target, key) as unknown }));
  const saves: Promise<void>[] = [];
  const edited = (update: Uint8Array, origin: unknown) => { if (origin !== "remote") saves.push(controller.editFromEditor(update)); };
  controller.editorDocument.on("update", edited);
  try {
    deleteFirst(server); server.purgeDeletedBlocks(Date.now() + 1);
    await controller.sync();
    editor.commands.insertContent({ type: "text", text: "確定" });
    await Promise.all(saves);
    expect([...controller.recoveries.values()].map((entry) => entry.blocks.map((block) => block.text))).toEqual([["日確定本語"]]);
    composing.mockRestore(); editor.destroy(); controller.editorDocument.off("update", edited); release();
    await expect(controller.flush()).rejects.toThrow("recovery offline");
    expect(controller.hasUnsent()).toBe(true);
    api.saveDocumentRecovery.mockResolvedValue({});
    await controller.flush();
    expect(controller.hasUnsent()).toBe(false);
    expect(server.projection().text).toBe("tail");
    const saved = api.saveDocumentRecovery.mock.calls.at(-1)![0] as { body: DocumentRecovery };
    expect(saved.body.blocks[0]?.text).toBe("日確定本語");
  } finally { composing.mockRestore(); editor.destroy(); controller.stop(); server.destroy(); }
});

it.each([false, true])("retains offline input after physical purge, including queued local save and recovery upload retry (queued=%s)", async (queued) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", uuidV7()), workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 0, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "seed",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  api.getSession.mockResolvedValue({ user: { id: user } });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  api.saveDocumentRecovery.mockRejectedValue(new Error("recovery offline"));
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { update?: string; vector: string } }) => {
    if (body.update) server.apply(body.update);
    return { generation, revision: 1, update: server.difference(body.vector) };
  });
  const controller = new BrowserDocument(user, workspace, initial.meetingId, initial);
  controller.listeners.add(() => {});
  try {
    const vector = Y.encodeStateVector(controller.editorDocument);
    firstText(controller.editorDocument).insert(4, " OFFLINE");
    const saving = controller.editFromEditor(Y.encodeStateAsUpdate(controller.editorDocument, vector));
    if (!queued) await saving;
    deleteFirst(server); server.purgeDeletedBlocks(Date.now() + 1);
    if (queued) await controller.session.accept(server.checkpoint(), false, { generation, revision: 1 });
    await saving;
    await expect(controller.flush()).rejects.toThrow("recovery offline");
    expect(controller.hasUnsent()).toBe(true);
    expect([...controller.recoveries.values()].map((recovery) => recovery.blocks.map((block) => block.text))).toEqual([["seed OFFLINE"]]);
    expect(server.projection().text).toBe("");
    api.saveDocumentRecovery.mockResolvedValue({});
    await controller.flush();
    expect(controller.hasUnsent()).toBe(false);
    const saved = api.saveDocumentRecovery.mock.calls.at(-1)![0] as { body: DocumentRecovery };
    expect(saved.body.reason).toBe("concurrent_delete");
    expect(saved.body.blocks.map((block) => block.text)).toEqual(["seed OFFLINE"]);
  } finally { controller.stop(); server.destroy(); }
});

it.each([false, true])("refreshes a restored document generation without acknowledging rejected edits (pending=%s)", async (pending) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meetingId = uuidV7(), oldGeneration = uuidV7(), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", meetingId), workspaceId: workspace,
    kind: "notes" as const, title: "", generation: oldGeneration, revision: 9, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "seed",
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
    const text = firstText(controller.editorDocument);
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
    kind: "notes" as const, title: "", generation, revision: 1, schemaVersion: 2, checkpoint: server.checkpoint(), text: "seed", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
  });
  const replace = (value: string) => {
    let update: Uint8Array = new Uint8Array();
    const listener = (bytes: Uint8Array) => { update = bytes; };
    controller.editorDocument.on("update", listener);
    const text = firstText(controller.editorDocument);
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
    expect(api.initializeMeetingNotes).toHaveBeenCalledWith({ headers: { "X-Dahlia-Document-User": userId }, params: { path: { workspaceId, meetingId } }, body: { id: proposed } }, false);
    expect(controller.params.path.documentId).toBe(canonical);
    expect(server.projection().text).toBe("offline input");
    expect(controller.hasUnsent()).toBe(false);
  } finally { controller.stop(); server.destroy(); edited.destroy(); }
});

it("rejects v1 remote data without acknowledging local changes", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const controller = new BrowserDocument(encodeId("user", uuidV7()), encodeId("workspace", uuidV7()), encodeId("meeting", uuidV7()), null);
  api.getSession.mockResolvedValue({ user: { id: controller.userId } });
  const edited = new DocumentCore(); edited.insertText("retained", uuidV7);
  api.initializeMeetingNotes.mockResolvedValue({ document: { id: encodeId("document", uuidV7()), generation: uuidV7() } });
  api.exchangeDocument.mockResolvedValue({ generation: uuidV7(), revision: 1, update: oldFixture.checkpoint });
  try {
    const update = Y.encodeStateAsUpdate(edited.document); Y.applyUpdate(controller.editorDocument, update);
    await controller.editFromEditor(update);
    await expect(controller.flush()).rejects.toThrow("unsupported_document_schema");
    expect(controller.hasUnsent()).toBe(true); expect(controller.copyText()).toBe("retained");
  } finally { controller.stop(); edited.destroy(); }
});

it("sends continuous typing within 100ms and receives invalidations while auxiliary reads are stalled", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  const handlers: ((event: { data: string }) => void)[] = [];
  vi.stubGlobal("EventSource", class {
    addEventListener(name: string, handler: (event: { data: string }) => void) { if (name === "document") handlers.push(handler); }
    close() {}
  });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", uuidV7()), workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 0, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "seed",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  const controllers = [0, 1].map(() => new BrowserDocument(user, workspace, initial.meetingId, initial, true, new SyncNotifications()));
  controllers.forEach((controller) => controller.listeners.add(() => {}));
  let revision = 0;
  api.exchangeDocument.mockImplementation(async ({ body, headers }: { body: { update?: string; vector: string }; headers: Record<string, string> }) => {
    expect(headers["X-Dahlia-Document-User"]).toBe(user);
    await new Promise((resolve) => setTimeout(resolve, 20));
    if (body.update) { server.apply(body.update); revision++; handlers.forEach((handler) => handler({ data: JSON.stringify({ workspaceId: workspace, meetingId: initial.meetingId, documentId: initial.id, cursor: `${generation}:${revision}`, unavailable: false }) })); }
    return { generation, revision, update: server.difference(body.vector) };
  });
  let unblock!: () => void;
  const blocked = new Promise<void>((resolve) => { unblock = resolve; });
  api.listDocumentRecoveries.mockImplementation(async () => { await blocked; return { items: [], nextCursor: null }; });
  api.getDocumentPresence.mockImplementation(async () => { await blocked; return { items: [] }; });
  const edit = async (value: string) => {
    const doc = controllers[0]!.editorDocument, vector = Y.encodeStateVector(doc);
    const text = firstText(doc);
    text.insert(text.length, value); await controllers[0]!.editFromEditor(Y.encodeStateAsUpdate(doc, vector));
  };
  const releases = controllers.map((controller) => controller.retainView());
  try {
    await vi.advanceTimersByTimeAsync(40); api.exchangeDocument.mockClear();
    await edit("a"); await vi.advanceTimersByTimeAsync(60); await edit("b");
    await vi.advanceTimersByTimeAsync(39); expect(api.exchangeDocument).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1); expect(api.exchangeDocument).toHaveBeenCalledTimes(1);
    await edit("c"); // Must get a follow-up exchange after the in-flight batch.
    await vi.advanceTimersByTimeAsync(100);
    expect(controllers[1]!.copyText()).toBe("seedabc");
    expect(api.getSession).not.toHaveBeenCalled();
    await edit("d"); await vi.advanceTimersByTimeAsync(200);
    expect(controllers[1]!.copyText()).toBe("seedabcd");
    const flushed = controllers[0]!.flush();
    await vi.advanceTimersByTimeAsync(40); await flushed; // Does not wait for stuck presence/history.
  } finally { releases.forEach((release) => release()); unblock(); controllers.forEach((controller) => controller.stop()); server.destroy(); }
});

it("retains unsent edits when the server rejects an account precondition", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meeting = encodeId("meeting", uuidV7());
  const controller = new BrowserDocument(user, workspace, meeting, null, true), edited = new DocumentCore();
  edited.insertText("retained", uuidV7); controller.listeners.add(() => {});
  api.initializeMeetingNotes.mockRejectedValue(new RequestError("document_account_changed", 409));
  try {
    const update = Y.encodeStateAsUpdate(edited.document); Y.applyUpdate(controller.editorDocument, update);
    await controller.editFromEditor(update);
    await expect(controller.flush()).rejects.toThrow("document_account_changed");
    expect(controller.hasUnsent()).toBe(true); expect(controller.copyText()).toBe("retained");
    expect(api.exchangeDocument).not.toHaveBeenCalled();
  } finally { controller.stop(); edited.destroy(); }
});


it("discovers the first edit from another tab without creating an empty document", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("EventSource", class { addEventListener() {} close() {} });
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meeting = encodeId("meeting", uuidV7());
  const controller = new BrowserDocument(user, workspace, meeting, null, true), created = new DocumentCore();
  controller.listeners.add(() => {}); created.insertText("first edit", uuidV7);
  api.getMeetingNotes.mockResolvedValue({ document: { id: encodeId("document", uuidV7()), generation: uuidV7() } });
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { generation: string; vector: string; update?: string } }) => {
    expect(body.update).toBeUndefined();
    return { generation: body.generation, revision: 1, update: created.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null }); api.getDocumentPresence.mockResolvedValue({ items: [] });
  const release = controller.retainView();
  try {
    await vi.advanceTimersByTimeAsync(250);
    expect(controller.copyText()).toBe("first edit");
    expect(api.initializeMeetingNotes).not.toHaveBeenCalled(); expect(api.getSession).not.toHaveBeenCalled();
  } finally { release(); controller.stop(); created.destroy(); }
});

it("unsubscribes a closed view while preserving and retrying its unsent conflict recovery", async () => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  const close = vi.fn();
  vi.stubGlobal("EventSource", class { addEventListener() {} close = close; });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: encodeId("meeting", uuidV7()), workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 0, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "seed",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { vector: string; update?: string } }) => {
    if (body.update) server.apply(body.update);
    return { generation, revision: 1, update: server.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null }); api.getDocumentPresence.mockResolvedValue({ items: [] });
  api.saveDocumentRecovery.mockRejectedValueOnce(new Error("offline")).mockResolvedValue(undefined);
  const controller = new BrowserDocument(user, workspace, initial.meetingId, initial, true, new SyncNotifications());
  const release = controller.retainView();
  try {
    await vi.advanceTimersByTimeAsync(0);
    const doc = controller.editorDocument, vector = Y.encodeStateVector(doc);
    firstText(doc).insert(4, " pending");
    await controller.editFromEditor(Y.encodeStateAsUpdate(doc, vector));
    deleteFirst(server.document);
    await controller.session.accept(server.checkpoint(), false);
    release(); expect(close).toHaveBeenCalledOnce(); expect(controller.hasUnsent()).toBe(true);
    await vi.advanceTimersByTimeAsync(100);
    expect(api.saveDocumentRecovery).toHaveBeenCalledOnce(); expect(controller.hasUnsent()).toBe(true);
    expect([...controller.recoveries.values()][0]?.blocks[0]?.text).toBe("seed pending");
    await controller.flush();
    expect(api.saveDocumentRecovery).toHaveBeenCalledTimes(2); expect(controller.hasUnsent()).toBe(false);
    expect(close).toHaveBeenCalledOnce(); expect(vi.getTimerCount()).toBe(0);
  } finally { release(); controller.stop(); server.destroy(); }
});
it.each(["sync", "flush"] as const)("rearms Notes hints after %s recovers access, only while the view is retained", async (operation) => {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  class Source extends EventTarget {
    static instances: Source[] = [];
    constructor() { super(); Source.instances.push(this); }
    close() {}
  }
  vi.stubGlobal("EventSource", Source);
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspace = encodeId("workspace", uuidV7()), meeting = encodeId("meeting", uuidV7()), generation = uuidV7();
  const initial = { id: encodeId("document", uuidV7()), meetingId: meeting, workspaceId: workspace,
    kind: "notes" as const, title: "", generation, revision: 1, schemaVersion: 2 as const, checkpoint: server.checkpoint(), text: "seed",
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  const notifications = new SyncNotifications(), stopDomain = notifications.subscribeDomain(user, () => {});
  const controller = new BrowserDocument(user, workspace, meeting, initial, true, notifications);
  let revision = 1;
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { vector: string } }) => ({ generation, revision, update: server.difference(body.vector) }));
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null }); api.getDocumentPresence.mockResolvedValue({ items: [] });
  const release = controller.retainView();
  const hint = (source: Source, unavailable: boolean) => source.dispatchEvent(new MessageEvent("document", { data: JSON.stringify({
    workspaceId: workspace, meetingId: meeting, documentId: initial.id, cursor: unavailable ? "unavailable" : `${generation}:${revision}`, unavailable,
  }) }));
  const recover = () => operation === "sync" ? controller.sync() : controller.flush();
  const deny = async () => {
    hint(Source.instances.at(-1)!, true);
    await vi.advanceTimersByTimeAsync(1);
    Source.instances.at(-1)!.dispatchEvent(new Event("open"));
  };
  try {
    await vi.advanceTimersByTimeAsync(1);
    Source.instances.at(-1)!.dispatchEvent(new Event("open")); await vi.advanceTimersByTimeAsync(1);
    await deny();
    const removed = Source.instances.length;
    api.exchangeDocument.mockRejectedValueOnce(new RequestError("document_unavailable", 404));
    await expect(recover()).rejects.toThrow("document_unavailable"); await vi.advanceTimersByTimeAsync(1);
    expect(Source.instances).toHaveLength(removed);
    await recover(); await vi.advanceTimersByTimeAsync(1);
    expect(Source.instances).toHaveLength(removed + 1);
    const text = firstText(server.document);
    text.insert(text.length, " remote"); revision++;
    hint(Source.instances.at(-1)!, false); await vi.advanceTimersByTimeAsync(1);
    expect(controller.copyText()).toBe("seed remote");

    await deny();
    const detached = Source.instances.length;
    let resolve!: (value: { generation: string; revision: number; update: string }) => void;
    api.exchangeDocument.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
    const inFlight = recover(); await vi.advanceTimersByTimeAsync(1);
    release();
    resolve({ generation, revision, update: server.difference(controller.session.core.vector()) });
    await inFlight; await vi.advanceTimersByTimeAsync(1);
    expect(Source.instances).toHaveLength(detached);
  } finally { release(); stopDomain(); controller.stop(); server.destroy(); }
});
