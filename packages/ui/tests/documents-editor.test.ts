import { afterEach, describe, expect, it, vi } from "vitest";
import { Editor } from "@tiptap/core";
import * as Y from "yjs";
import { DocumentCore, decodeBinary, encodeBinary, type DocumentBlock } from "../src/documents/core";
import { blockMap, blockText, rootOrder, writeBlocks } from "../src/documents/blocks";
import { DocumentEditorHydration, documentEditorOptions, moveBlock } from "../src/documents/editor";

const owned: { destroy(): void }[] = [];
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); owned.reverse().forEach((value) => value.destroy()); owned.length = 0; });
function editor(text = "first\nsecond", checkpoint?: string, editable = true) {
  const core = new DocumentCore(checkpoint); owned.push(core);
  if (!checkpoint) core.insertText(text, () => crypto.randomUUID());
  const errors: string[] = [];
  const recovered: DocumentBlock[] = [];
  const editor = new Editor({ ...documentEditorOptions(core.document, editable, "", (error) => errors.push(error), (blocks) => recovered.push(...blocks)), element: null });
  // Tiptap installs plugins at mount. Install those same plugins in the headless state.
  editor.view.updateState(editor.state.reconfigure({ plugins: editor.extensionManager.plugins }));
  owned.push(editor);
  return { core, editor, errors, recovered };
}
const insert = (editor: Editor, text: string) => editor.commands.insertContent({ type: "text", text });

describe("Documents editor binding", () => {
  it.each([false, true])("does not clone the document for a no-op host checkpoint (edited=%s)", (edited) => {
    const a = editor(), hydration = new DocumentEditorHydration(a.core.document);
    if (edited) hydration.edited();
    const checkpoint = decodeBinary(a.core.checkpoint());
    const destroy = vi.spyOn(Y.Doc.prototype, "destroy");
    hydration.receive(checkpoint);
    expect(destroy).not.toHaveBeenCalled();
  });
  it.each(["first", "later", "known-clocks", "intermediate"])("preserves ordinary input when purge races the host save (%s)", (scenario) => {
    const a = editor("日本語\ntail"), b = editor("", a.core.checkpoint());
    const hydration = new DocumentEditorHydration(a.core.document, (blocks) => a.recovered.push(...blocks));
    if (scenario === "later") hydration.captureLocalUpdate(new Uint8Array([0, 0]));
    const pending: Uint8Array[] = [];
    a.core.document.on("update", (update, origin) => { if (origin !== "remote") { hydration.edited(); pending.push(update); } });
    a.editor.commands.setTextSelection(2); insert(a.editor, "保存前");
    const id = rootOrder(b.core.document).get(0);
    if (scenario === "intermediate") hydration.receive(decodeBinary(b.core.checkpoint()));
    writeBlocks(b.core.document, { blocks: [], removed: [id], order: new Map() }, "remote");
    b.core.purgeDeletedBlocks(Date.now() + 1);
    // The host can receive the delta after purge: it knows the clocks but never had the body.
    if (scenario === "known-clocks") b.core.apply(encodeBinary(Y.mergeUpdates(pending)));
    hydration.receive(decodeBinary(b.core.checkpoint()));
    b.core.apply(encodeBinary(hydration.captureLocalUpdate(Y.mergeUpdates(pending))));
    expect(a.recovered).toEqual([{ id, type: "paragraph", text: "日保存前本語" }]);
    expect(a.core.projection().text).toBe("tail");
    expect(b.core.projection().text).toBe("tail");
    hydration.receive(decodeBinary(b.core.checkpoint()));
    expect(a.recovered).toHaveLength(1);
  });
  it("leaves already-confirmed input recovery to the host", () => {
    const a = editor("日本語\ntail"), b = editor("", a.core.checkpoint());
    const hydration = new DocumentEditorHydration(a.core.document, (blocks) => a.recovered.push(...blocks));
    a.editor.commands.setTextSelection(2); insert(a.editor, "保存済み"); hydration.edited();
    b.core.apply(a.core.checkpoint());
    hydration.receive(decodeBinary(b.core.checkpoint()));
    writeBlocks(b.core.document, { blocks: [], removed: [rootOrder(b.core.document).get(0)], order: new Map() }, "remote");
    b.core.purgeDeletedBlocks(Date.now() + 1);
    hydration.receive(decodeBinary(b.core.checkpoint()));
    expect(a.recovered).toEqual([]);
  });
  it.each([false, true])("preserves committed IME input when a remote deletion hides its body (purge=%s)", async (purge) => {
    vi.useFakeTimers();
    const a = editor("日本語\ntail"), b = editor("", a.core.checkpoint());
    const id = rootOrder(b.core.document).get(0);
    a.editor.commands.setTextSelection(2);
    let composing = true;
    const view = a.editor.view;
    vi.spyOn(a.editor, "view", "get").mockReturnValue(new Proxy(view, { get: (target, key): unknown => key === "composing" ? composing : Reflect.get(target, key) as unknown }));
    writeBlocks(b.core.document, { blocks: [], removed: [id], order: new Map() }, "remote");
    if (purge) b.core.purgeDeletedBlocks(Date.now() + 1);
    a.core.apply(b.core.checkpoint());
    insert(a.editor, "確定");
    // Recovery must reach the host before flush/detach can destroy the causal draft.
    expect(a.recovered).toEqual([{ id, type: "paragraph", text: "日確定本語" }]);
    expect(a.errors).toEqual([]);
    composing = false;
    for (const plugin of a.editor.state.plugins) plugin.props.handleDOMEvents?.compositionend?.call(plugin, a.editor.view, {} as CompositionEvent);
    await vi.advanceTimersByTimeAsync(50);
    expect(a.core.projection().text).toBe("tail");
    expect(a.editor.state.doc.textContent).toBe("tail");
    expect(a.recovered).toHaveLength(1);
  });
  it("accepts concurrent node-type and attribute changes regardless of register winners", () => {
    const a = editor("heading"); a.editor.commands.toggleHeading({ level: 1 });
    const b = editor("", a.core.checkpoint());
    a.core.document.clientID = 1; b.core.document.clientID = 2;
    a.editor.commands.setParagraph(); b.editor.commands.toggleHeading({ level: 2 });
    const updateA = a.core.checkpoint(), updateB = b.core.checkpoint();
    a.core.apply(updateB); b.core.apply(updateA);
    expect(a.core.projection()).toEqual(b.core.projection());
    expect(a.editor.getJSON()).toEqual(b.editor.getJSON());
    expect(a.editor.state.doc.firstChild!.type.name).toBe("paragraph");
  });
  it("defers remote rendering during composition and merges the committed IME text", async () => {
    vi.useFakeTimers();
    const a = editor("日本語"), b = editor("", a.core.checkpoint());
    a.editor.commands.setTextSelection(2);
    let composing = true;
    const view = a.editor.view;
    vi.spyOn(a.editor, "view", "get").mockReturnValue(new Proxy(view, { get: (target, key): unknown => key === "composing" ? composing : Reflect.get(target, key) as unknown }));
    b.editor.commands.setTextSelection(4); insert(b.editor, " remote"); a.core.apply(b.core.checkpoint());
    expect(a.editor.state.doc.textContent).toBe("日本語");
    insert(a.editor, "確定");
    composing = false;
    for (const plugin of a.editor.state.plugins) plugin.props.handleDOMEvents?.compositionend?.call(plugin, a.editor.view, {} as CompositionEvent);
    await vi.advanceTimersByTimeAsync(50);
    expect(a.editor.state.doc.textContent).toBe("日確定本語 remote");
    expect(a.core.projection().text).toBe(a.editor.state.doc.textContent);
  });
  it("preserves the leaf identity and concurrent typing through list indent/lift", () => {
    const a = editor("one\ntwo");
    a.editor.commands.selectAll(); a.editor.commands.toggleBulletList();
    const b = editor("", a.core.checkpoint()), vector = a.core.vector();
    let position = 0, id = "";
    a.editor.state.doc.descendants((node, pos) => { if (node.isTextblock && node.textContent === "two") { position = pos + 1; id = node.attrs.id as string; } });
    a.editor.commands.setTextSelection(position); b.editor.commands.setTextSelection(position + 3);
    a.editor.commands.sinkListItem("listItem"); insert(b.editor, " concurrent");
    const move = a.core.difference(vector), edit = b.core.difference(vector);
    a.core.apply(edit); b.core.apply(move);
    expect(a.editor.getJSON()).toEqual(b.editor.getJSON());
    expect(a.core.projection().blocks.find((block) => block.id === id)?.text).toBe("two concurrent");
    a.editor.commands.liftListItem("listItem");
    expect(a.core.projection().blocks.find((block) => block.id === id)?.text).toBe("two concurrent");
  });
  it("keeps typed text in a concurrently moved block and through move undo/redo", () => {
    const a = editor(), b = editor("", a.core.checkpoint());
    const checkpoint = a.core.checkpoint(), vector = a.core.vector(), id = rootOrder(a.core.document).get(0);
    expect(moveBlock(a.editor, id, a.editor.state.doc.content.size)).toBe(true);
    b.editor.commands.setTextSelection(6); insert(b.editor, " typed");
    const ua = a.core.difference(vector), ub = b.core.difference(vector);
    a.core.apply(ub); b.core.apply(ua);
    expect(a.editor.getText()).toBe("second\n\nfirst typed");
    expect(b.editor.getJSON()).toEqual(a.editor.getJSON());
    a.editor.commands.undo();
    expect(a.core.projection().text).toBe("first typed\nsecond");
    a.editor.commands.redo(); expect(a.core.projection().text).toBe("second\nfirst typed");
    expect(new DocumentCore(checkpoint).projection().blocks[0]!.id).toBe(id);
  });
  it("retains IDs through heading and list conversions, split and join", () => {
    const a = editor("first"), id = rootOrder(a.core.document).get(0);
    a.editor.commands.setTextSelection(3); a.editor.commands.toggleHeading({ level: 2 });
    expect(a.core.projection().blocks[0]!.id).toBe(id);
    a.editor.commands.toggleBulletList();
    expect(a.core.projection().text).toBe("first");
    expect(a.core.projection().blocks[0]!.id).toBe(id);
    a.editor.commands.toggleOrderedList();
    expect(a.core.projection().blocks[0]!.id).toBe(id);
    a.editor.commands.toggleOrderedList();
    a.editor.commands.setTextSelection(3); a.editor.commands.splitBlock();
    const split = a.core.projection().blocks;
    expect(split.map((block) => block.text)).toEqual(["fi", "rst"]);
    expect(split[0]!.id).toBe(id); expect(split[1]!.id).not.toBe(id);
    a.editor.commands.joinBackward(); expect(a.core.projection().text).toBe("first");
    expect(a.core.projection().blocks[0]!.id).toBe(id);
  });
  it("rekeys pasted duplicates without reviving tombstones", () => {
    const a = editor("first"), original = a.editor.getJSON().content[0]!;
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, original);
    const ids = a.core.projection().blocks.map((block) => block.id);
    expect(new Set(ids).size).toBe(2);
    a.editor.commands.deleteRange({ from: 0, to: a.editor.state.doc.firstChild!.nodeSize });
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, original);
    expect(a.core.projection().blocks.map((block) => block.id)).not.toContain(ids[0]);
  });
  it("rejects 9,000 paragraphs before allocating Yjs clocks and remains editable", () => {
    const a = editor("safe"), checkpoint = a.core.checkpoint();
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, Array.from({ length: 9_000 }, () => ({ type: "paragraph" })));
    expect(a.errors).toEqual(["document_too_large"]); expect(a.core.checkpoint()).toBe(checkpoint);
    a.editor.commands.setTextSelection(5); insert(a.editor, " edit");
    expect(a.core.projection().text).toBe("safe edit");
  });
  it("counts pasted duplicate IDs toward the retained block limit before normalization", () => {
    const seed = new DocumentCore(); owned.push(seed);
    const blocks = Array.from({ length: 8_000 }, (_, i) => ({ id: `block-${i}`, type: "paragraph" as const, attrs: {}, parent: null, text: [{ insert: "a" }] }));
    writeBlocks(seed.document, { blocks, removed: [], order: new Map([[null, blocks.map((block) => block.id)]]) }, null);
    writeBlocks(seed.document, { blocks: [], removed: blocks.slice(1).map((block) => block.id), order: new Map() }, null);
    const a = editor("", seed.checkpoint()), checkpoint = a.core.checkpoint();
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, a.editor.getJSON().content[0]!);
    expect(a.errors).toEqual(["document_too_large"]);
    expect(a.core.checkpoint()).toBe(checkpoint);
    a.editor.commands.setTextSelection(2); insert(a.editor, " edit");
    expect(a.core.projection().text).toBe("a edit");
  });
  it.each([false, true])("preflights history before writing clocks and permits retry after remote deletion (redo=%s)", (redo) => {
    const a = editor(redo ? "first" : "first\nsecond");
    if (redo) {
      a.editor.commands.insertContentAt(a.editor.state.doc.content.size, { type: "paragraph", content: [{ type: "text", text: "second" }] });
      a.editor.commands.undo();
    } else a.editor.commands.deleteRange({ from: 0, to: a.editor.state.doc.firstChild!.nodeSize });
    const blocks = Array.from({ length: 4_999 }, (_, i) => ({ id: `remote-${i}`, type: "paragraph" as const, attrs: {}, parent: null, text: [] }));
    writeBlocks(a.core.document, { blocks, removed: [], order: new Map([[null, [...rootOrder(a.core.document).toArray(), ...blocks.map((block) => block.id)]]]) }, "remote");
    const checkpoint = a.core.checkpoint();
    expect(a.core.projection().blocks).toHaveLength(5_000);
    expect(redo ? a.editor.commands.redo() : a.editor.commands.undo()).toBe(false);
    expect(a.errors).toEqual(["document_too_large"]); expect(a.core.checkpoint()).toBe(checkpoint);
    writeBlocks(a.core.document, { blocks: [], removed: ["remote-0"], order: new Map() }, "remote");
    expect(redo ? a.editor.commands.redo() : a.editor.commands.undo()).toBe(true);
    expect(a.core.projection().blocks).toHaveLength(5_000);
    expect(a.core.projection().blocks.filter((block) => block.text).map((block) => block.text)).toEqual(["first", "second"]);
  });
  it("previews repeated history across redone links without changing earlier undo behavior", () => {
    const a = editor("first"), b = editor("", a.core.checkpoint());
    a.editor.commands.setTextSelection(3); insert(a.editor, "X");
    (a.editor.storage as unknown as { dahliaDocument: { binding: { undoManager: Y.UndoManager } } }).dahliaDocument.binding.undoManager.stopCapturing();
    insert(a.editor, "Y");
    b.editor.commands.setTextSelection(6); insert(b.editor, " remote"); a.core.apply(b.core.checkpoint());
    a.editor.commands.undo(); expect(a.core.projection().text).toBe("fiXrst remote");
    a.editor.commands.redo(); expect(a.core.projection().text).toBe("fiXYrst remote");
    a.editor.commands.undo(); a.editor.commands.undo(); expect(a.core.projection().text).toBe("first remote");
  });
  it("rejects URL and text limits before modifying the shared state", () => {
    const a = editor("safe"), checkpoint = a.core.checkpoint();
    a.editor.commands.selectAll(); a.editor.commands.setLink({ href: `https://example.com/${"a".repeat(8_192)}` });
    expect(a.errors).toContain("document_too_large"); expect(a.core.checkpoint()).toBe(checkpoint);
    insert(a.editor, "x".repeat(2_000_001)); expect(a.core.checkpoint()).toBe(checkpoint);
  });
  it("counts retained Japanese bodies in byte preflight, then accepts after canonical purge", () => {
    const text = "日".repeat(1_600_000), a = editor(text);
    a.editor.commands.selectAll(); a.editor.commands.deleteSelection();
    // Deleting text in-place releases the body except for Undo. Delete the block instead.
    a.editor.commands.undo();
    const first = a.editor.state.doc.firstChild!;
    a.editor.commands.insertContentAt(first.nodeSize, { type: "paragraph", content: [{ type: "text", text: "tail" }] });
    a.editor.commands.deleteRange({ from: 0, to: first.nodeSize });
    const checkpoint = a.core.checkpoint(false);
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, { type: "paragraph", content: [{ type: "text", text }] });
    expect(a.errors).toContain("document_too_large"); expect(a.core.checkpoint(false)).toBe(checkpoint);
    const canonical = new DocumentCore(checkpoint); owned.push(canonical);
    canonical.purgeDeletedBlocks(Date.now() + 1); a.core.apply(canonical.checkpoint());
    a.editor.commands.insertContentAt(a.editor.state.doc.content.size, { type: "paragraph", content: [{ type: "text", text }] });
    expect(a.core.projection().text).toBe(`tail\n${text}`);
  });
  it("does not write from viewers, including commands", () => {
    const a = editor("safe", undefined, false), checkpoint = a.core.checkpoint();
    insert(a.editor, "wrong"); expect(a.core.checkpoint()).toBe(checkpoint);
    expect(moveBlock(a.editor, rootOrder(a.core.document).get(0), 6)).toBe(false);
  });
  it("applies remote changes beyond the local content limit", () => {
    const a = editor("safe"), remote = new DocumentCore(a.core.checkpoint()); owned.push(remote);
    const text = blockText(blockMap(remote.document).get(rootOrder(remote.document).get(0))!);
    text.insert(0, "x".repeat(2_000_001));
    Y.applyUpdate(a.core.document, Y.encodeStateAsUpdate(remote.document), "remote");
    expect(a.editor.state.doc.textContent.length).toBe(2_000_005);
    expect(a.errors).toEqual([]);
  });
});
