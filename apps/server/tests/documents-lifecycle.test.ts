import { afterEach, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { BrowserDocument, MeetingNotes, finishBrowserDocuments } from "../src/client/Documents";
import { DocumentCore, documentFragment } from "../src/documents/core";
import { encodeId } from "../src/typeid";
import { uuidV7 } from "../src/id";

// Run the real loading effect without mounting the editor, including the interval
// between a resolved load and React attaching the editor's subscription.
const hooks = vi.hoisted(() => ({ effect: null as (() => void | (() => void)) | null, state: vi.fn<(value: unknown) => void>() }));
vi.mock("react", async (importOriginal) => ({
  ...await importOriginal<typeof import("react")>(),
  useEffect: (effect: () => void | (() => void)) => { hooks.effect = effect; },
  useState: (initial: unknown) => [initial, hooks.state],
}));
const api = vi.hoisted(() => ({ getSession: vi.fn(), getCapabilities: vi.fn(), getDocument: vi.fn(), exchangeDocument: vi.fn(),
  listDocumentRecoveries: vi.fn(), getDocumentPresence: vi.fn() }));
vi.mock("../src/client/generated-operations", () => ({ apiOperations: api, apiUrls: { getDocumentEvents: () => "/events" } }));
afterEach(async () => { await finishBrowserDocuments(); vi.useRealTimers(); vi.unstubAllGlobals(); vi.clearAllMocks(); });

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((accept) => { resolve = accept; });
  return { promise, resolve };
}

function setup() {
  vi.useFakeTimers();
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
  const close = vi.fn(), created = vi.fn();
  vi.stubGlobal("EventSource", class { constructor() { created(); } addEventListener() {} close() { close(); } });
  const server = new DocumentCore(); server.insertText("seed", uuidV7);
  const user = encodeId("user", uuidV7()), workspaceId = encodeId("workspace", uuidV7()), id = uuidV7();
  const meetingId = encodeId("meeting", id), generation = uuidV7();
  const document = { id: encodeId("document", id), workspaceId, meetingId, generation, revision: 1, schemaVersion: 1,
    checkpoint: server.checkpoint(), text: "seed", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  api.getSession.mockResolvedValue({ user: { id: user } });
  api.getCapabilities.mockResolvedValue({ documents: { version: 1 } });
  api.getDocument.mockResolvedValue({ document });
  api.exchangeDocument.mockImplementation(async ({ body }: { body: { update?: string; vector: string } }) => {
    if (body.update) server.apply(body.update);
    return { generation, revision: 2, update: server.difference(body.vector) };
  });
  api.listDocumentRecoveries.mockResolvedValue({ items: [], nextCursor: null });
  api.getDocumentPresence.mockResolvedValue({ items: [] });
  const mount = () => {
    MeetingNotes({ workspaceId, meetingId, editable: true });
    const cleanup = hooks.effect?.();
    if (typeof cleanup !== "function") throw new Error("Missing Notes loading effect");
    return cleanup;
  };
  return { close, created, document, mount, server };
}

it("releases a Notes load that completes after its view closes", async () => {
  const f = setup();
  const fetched = deferred<{ document: typeof f.document }>();
  api.getDocument.mockReturnValueOnce(fetched.promise);
  const unmount = f.mount();
  try {
    await vi.waitFor(() => expect(api.getDocument).toHaveBeenCalledOnce());
    unmount();
    fetched.resolve({ document: f.document });
    await vi.waitFor(() => expect(f.close).toHaveBeenCalledOnce());
    expect(vi.getTimerCount()).toBe(0);
    expect(api.exchangeDocument).not.toHaveBeenCalled();
    expect(hooks.state.mock.calls.some(([value]) => value instanceof BrowserDocument)).toBe(false);
  } finally { fetched.resolve({ document: f.document }); f.server.destroy(); }
});

it.each([false, true])("keeps overlapping Notes loads alive until the last view leaves (pending=%s)", async (pending) => {
  const f = setup();
  const fetched = deferred<{ document: typeof f.document }>();
  api.getDocument.mockReturnValue(fetched.promise);
  const first = f.mount(), second = f.mount();
  try {
    await vi.waitFor(() => expect(api.getDocument).toHaveBeenCalledTimes(2));
    first();
    fetched.resolve({ document: f.document });
    await vi.waitFor(() => expect(hooks.state.mock.calls.some(([value]) => value instanceof BrowserDocument)).toBe(true));
    const controller = hooks.state.mock.calls.map(([value]) => value).find((value): value is BrowserDocument => value instanceof BrowserDocument)!;
    expect(f.created).toHaveBeenCalledOnce();
    expect(f.close).not.toHaveBeenCalled();
    const third = f.mount(); // Also acquire an already cached controller.
    await vi.waitFor(() => expect(hooks.state.mock.calls.filter(([value]) => value instanceof BrowserDocument)).toHaveLength(2));
    second(); second(); // Repeated cleanup must not release the other consumer's view.
    expect(f.close).not.toHaveBeenCalled();
    if (pending) {
      const vector = Y.encodeStateVector(controller.editorDocument);
      const text = (controller.editorDocument.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText;
      text.insert(text.length, " pending");
      await controller.editFromEditor(Y.encodeStateAsUpdate(controller.editorDocument, vector));
    }
    third();
    if (pending) {
      expect(f.close).not.toHaveBeenCalled();
      expect(controller.copyText()).toBe("seed pending");
      await controller.flush();
      expect(f.server.projection().text).toBe("seed pending");
    }
    expect(f.close).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  } finally { fetched.resolve({ document: f.document }); f.server.destroy(); }
});
