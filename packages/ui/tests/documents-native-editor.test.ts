import { afterEach, expect, it, vi } from "vitest";
import { DocumentCore, type DocumentBlock } from "../src/documents/core";
import { DocumentEditorHydration } from "../src/documents/editor";
import { firstText, deleteFirst } from "./fixtures/document-helpers";
import type * as Y from "yjs";

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.doUnmock("../src/documents/editor"); });

it("hands recovery and body updates to the same native batch on both drain and throttle", async () => {
  vi.useFakeTimers();
  let recover!: (blocks: DocumentBlock[]) => void;
  let document!: Y.Doc;
  const postMessage = vi.fn();
  vi.doMock("../src/documents/editor", () => ({ DocumentEditorHydration,
    mountDocumentEditor: (_element: unknown, doc: Y.Doc, _editable: boolean, _placeholder: string, _error: unknown, onRecovery: typeof recover) => {
      recover = onRecovery; document = doc;
      return { isEditable: true, on: (event: string, callback: () => void) => { if (event === "create") callback(); } };
    },
  }));
  vi.stubGlobal("window", { webkit: { messageHandlers: { document: { postMessage } } }, document: { getElementById() { return {}; }, addEventListener() {} } });
  await import("../src/documents/native-editor");
  const seed = new DocumentCore(); seed.insertText("seed", () => "first");
  window.dahliaDocument.open(seed.checkpoint(), true, "");
  const blocks = [{ id: "purged", type: "paragraph", text: "日確定本語" }];
  try {
    firstText(document).insert(4, " one"); recover(blocks);
    const drained = window.dahliaDocument.drain()!;
    expect(JSON.parse(drained.recovery!)).toEqual(blocks);
    seed.apply(drained.update);
    expect(seed.projection().text).toBe("seed one");
    expect(window.dahliaDocument.drain()).toBeNull();
    await vi.advanceTimersByTimeAsync(50);
    expect(postMessage).toHaveBeenCalledTimes(1); // ready only; drained data must not be sent twice
    firstText(document).insert(8, " two"); recover(blocks);
    await vi.advanceTimersByTimeAsync(50);
    const batch = postMessage.mock.calls.at(-1)![0] as { type: string; update: string; recovery: string };
    expect(batch.type).toBe("update"); expect(JSON.parse(batch.recovery)).toEqual(blocks);
    seed.apply(batch.update);
    expect(seed.projection().text).toBe("seed one two");
    expect(window.dahliaDocument.drain()).toBeNull();
    // The pending normal edit has not reached the host when its purge arrives.
    firstText(document).insert(12, " 保存前");
    deleteFirst(seed); seed.purgeDeletedBlocks(Date.now() + 1);
    window.dahliaDocument.receive(seed.checkpoint());
    const late = window.dahliaDocument.drain()!;
    expect(JSON.parse(late.recovery!)).toEqual([{ id: "first", type: "paragraph", text: "seed one two 保存前" }]);
    seed.apply(late.update);
    expect(seed.projection().text).toBe("");
    expect(window.dahliaDocument.drain()).toBeNull();
  } finally { document.destroy(); seed.destroy(); }
});
