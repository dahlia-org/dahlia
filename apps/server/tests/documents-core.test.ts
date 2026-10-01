import { describe, expect, it } from "vitest";
import * as Y from "yjs";
import { getSchema } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Fragment, type Node } from "@tiptap/pm/model";
import fixture from "../../desktop/Tests/DahliaTests/Fixtures/documents.json";
import { DocumentCore, decodeBinary, documentStateLimit, encodeBinary, mergeDocumentUpdates, removedBlocks, type DocumentRecovery } from "../src/documents/core";
import { blockLayout, blockMap, renderedAttributes, rootOrder, writeBlocks, writeInline, type BlockInput } from "../src/documents/blocks";
import { DocumentEditorHydration, pastedTextSlice, withoutTrailingBreaks } from "../src/documents/editor";
import { DocumentSession, type DocumentHost, type PendingDocumentUpdate } from "../src/documents/session";
import { run as runNativeDocument } from "../src/documents/native-core";
import { deleteFirst, firstText } from "./fixtures/document-helpers";
const id = () => crypto.randomUUID();
const seed = (value = "before\nstays") => { const core = new DocumentCore(); core.insertText(value, id); return core; };
const order = (core: DocumentCore, ids: string[], origin: unknown = "move") => writeBlocks(core.document, { blocks: [], removed: [], order: new Map([[null, ids]]) }, origin);

describe("portable document core v2", () => {
  it.each([false, true])("uses the same fixture in Node, Workers and JavaScriptCore (difference=%s)", (difference) => {
    const core = new DocumentCore(fixture.checkpoint);
    const vector = difference ? core.vector() : undefined;
    fixture.updates.forEach((update) => core.apply(update));
    expect(core.projection()).toEqual({ text: fixture.text, blocks: fixture.blocks });
    const result = JSON.parse(runNativeDocument(JSON.stringify({ checkpoint: fixture.checkpoint, updates: fixture.updates, vector }))) as {
      checkpoint: string; vector: string; update: string; projection: unknown;
    };
    expect(result.projection).toEqual(core.projection());
    expect(result.checkpoint).toBe(core.checkpoint());
    expect(result.vector).toBe(core.vector());
    expect(result.update).toBe(vector ? core.difference(vector) : result.checkpoint);
    core.destroy();
  });
  it("renders only the current block type's attributes, preserving defaults", () => {
    const document = new Y.Doc(), block = document.getMap("block");
    try {
      block.set("attrs", {});
      expect(renderedAttributes("heading", block)).toEqual({ level: 1 });
      expect(renderedAttributes("orderedList", block)).toEqual({ start: 1, type: null });
      block.set("attrs", { level: 3, start: 0, type: "A" });
      expect(renderedAttributes("heading", block)).toEqual({ level: 3 });
      expect(renderedAttributes("orderedList", block)).toEqual({ start: 0, type: "A" });
      expect(renderedAttributes("paragraph", block)).toEqual({});
    } finally { document.destroy(); }
  });
  it("round trips binary without platform base64 APIs", () => {
    for (let count = 0; count < 260; count++) {
      const bytes = Uint8Array.from({ length: count }, (_, i) => i % 256);
      expect(encodeBinary(bytes)).toBe(Buffer.from(bytes).toString("base64"));
      expect(decodeBinary(encodeBinary(bytes))).toEqual(bytes);
    }
    expect(() => decodeBinary("bad!")).toThrow("invalid_document_update");
    expect(() => decodeBinary(Buffer.alloc(documentStateLimit + 1).toString("base64"))).toThrow("invalid_document_update");
  });
  it.each(["# 見出しではない\r\n\n- メモ\n", "\n".repeat(5_200)])("preserves literal imports and groups excess lines", (text) => {
    const core = seed(text);
    expect(new DocumentCore(core.checkpoint()).projection().text).toBe(text);
    expect(core.projection().blocks.length).toBeLessThanOrEqual(5_000);
    core.destroy();
  });
  it("matches the v1 plain-text contract for headings, lists, marks, empty paragraphs and breaks", () => {
    const core = new DocumentCore();
    const blocks: BlockInput[] = [
      { id: "h", type: "heading", attrs: { level: 2 }, parent: null, text: [{ insert: "heading", attributes: { bold: {} } }] },
      { id: "list", type: "bulletList", attrs: {}, parent: null },
      { id: "item", type: "listItem", attrs: {}, parent: "list" },
      { id: "p", type: "paragraph", attrs: {}, parent: "item", text: [{ insert: "one" }] },
      { id: "q", type: "paragraph", attrs: {}, parent: "item", text: [{ insert: "two" }] },
      { id: "br", type: "paragraph", attrs: {}, parent: null, text: [{ insert: "a" }, { insert: { type: "hardBreak" } }, { insert: "b" }] },
      { id: "empty", type: "paragraph", attrs: {}, parent: null, text: [] },
      { id: "crlf", type: "paragraph", attrs: {}, parent: null, text: [{ insert: "a\r" }] },
    ];
    writeBlocks(core.document, { blocks, removed: [], order: new Map([[null, ["h", "list", "br", "empty", "crlf"]], ["list", ["item"]], ["item", ["p", "q"]]]) }, null);
    expect(core.projection().text).toBe(fixture.v1.text);
    expect(core.projection().blocks.map((block) => block.id)).toEqual(["h", "p", "q", "item", "list", "br", "empty", "crlf"]);
    core.destroy();
  });
  it.each([false, true])("converges move versus typing in either delivery order (%s)", (reverse) => {
    const initial = seed(), a = new DocumentCore(initial.checkpoint()), b = new DocumentCore(initial.checkpoint());
    const ids = rootOrder(a.document).toArray();
    order(a, ids.toReversed()); firstText(b).insert(6, " concurrent");
    const updates = [a.difference(initial.vector()), b.difference(initial.vector())];
    const merged = new DocumentCore(initial.checkpoint());
    (reverse ? updates.toReversed() : updates).forEach((update) => merged.apply(update));
    a.apply(updates[1]!); b.apply(updates[0]!);
    expect(a.projection()).toEqual(b.projection()); expect(merged.projection()).toEqual(a.projection());
    expect(a.projection().text).toBe("stays\nbefore concurrent");
    initial.destroy(); a.destroy(); b.destroy(); merged.destroy();
  });
  it("keeps the other concurrent move after undo and canonical purge", () => {
    const initial = seed("a\nb\nc\nx"), a = new DocumentCore(initial.checkpoint()), b = new DocumentCore(initial.checkpoint());
    const [ai, bi, ci, xi] = rootOrder(a.document).toArray() as [string, string, string, string];
    const undo = new Y.UndoManager([blockMap(b.document), rootOrder(b.document)], { trackedOrigins: new Set(["move"]) });
    order(a, [ai, xi, bi, ci]); order(b, [xi, ai, bi, ci]);
    a.apply(b.difference(initial.vector())); b.apply(a.difference(initial.vector()));
    a.purgeDeletedBlocks(0); b.apply(a.checkpoint());
    undo.undo(); a.apply(b.checkpoint());
    expect(a.projection().text).toBe("a\nx\nb\nc"); expect(b.projection()).toEqual(a.projection());
    undo.destroy(); initial.destroy(); a.destroy(); b.destroy();
  });
  it.each([false, true])("recovers the merged deleted body, including unsent typing (%s)", (reverse) => {
    const initial = seed("before"), a = new DocumentCore(initial.checkpoint()), b = new DocumentCore(initial.checkpoint());
    firstText(a).insert(6, " UNSENT"); deleteFirst(a);
    firstText(b).insert(6, " remote");
    const before = initial.projection(), updates = [a.difference(initial.vector()), b.difference(initial.vector())];
    (reverse ? updates.toReversed() : updates).forEach((update) => initial.apply(update));
    const removed = removedBlocks(before, initial.projection());
    expect(removed[0]!.text).toContain("UNSENT"); expect(removed[0]!.text).toContain("remote");
    expect(initial.projection().text).toBe("");
    const hidden = initial.projection(); firstText(b).insert(0, "later "); initial.apply(b.checkpoint());
    expect(removedBlocks(hidden, initial.projection())[0]!.text).toContain("later");
    initial.destroy(); a.destroy(); b.destroy();
  });
  it("purges only expired bodies and supports undo before purge", () => {
    const core = seed("kept"), undo = new Y.UndoManager([blockMap(core.document), rootOrder(core.document)]);
    deleteFirst(core);
    const deletedAt = Date.now();
    core.purgeDeletedBlocks(deletedAt - 1000); expect(blockMap(core.document).size).toBe(1);
    undo.undo(); expect(core.projection().text).toBe("kept");
    undo.stopCapturing(); deleteFirst(core); undo.destroy();
    core.purgeDeletedBlocks(deletedAt + 1000); expect(blockMap(core.document).size).toBe(0);
    core.destroy();
  });
  it("recovers and collects a late child of a physically purged parent", () => {
    const core = new DocumentCore();
    writeBlocks(core.document, { blocks: [{ id: "l", type: "bulletList", attrs: {}, parent: null }], removed: [], order: new Map([[null, ["l"]]]) }, null);
    const offline = new DocumentCore(core.checkpoint());
    writeBlocks(core.document, { blocks: [], removed: ["l"], order: new Map() }, null); core.purgeDeletedBlocks(Date.now() + 1);
    writeBlocks(offline.document, { blocks: [{ id: "i", type: "listItem", attrs: {}, parent: "l" }, { id: "p", type: "paragraph", attrs: {}, parent: "i", text: [{ insert: "late" }] }], removed: [], order: new Map([["l", ["i"]], ["i", ["p"]]]) }, null);
    const before = core.projection(); core.apply(offline.checkpoint());
    expect(removedBlocks(before, core.projection()).map((block) => block.text)).toEqual(["late"]);
    core.purgeDeletedBlocks(0); expect(blockMap(core.document).size).toBe(0);
    core.destroy(); offline.destroy();
  });
  it("rejects v1 checkpoints and unresolved append/delete deltas", () => {
    expect(() => new DocumentCore(fixture.v1.checkpoint)).toThrow("unsupported_document_schema");
    for (const update of [fixture.v1.append, fixture.v1.deletion]) expect(() => new DocumentCore(update)).toThrow("invalid_document_update");
  });
  it("does not rewrite unaffected text or split surrogate pairs", () => {
    const core = seed("a😀b"), text = firstText(core);
    writeInline(text, [{ insert: "a😁b", attributes: { bold: {} } }]);
    expect(core.projection().text).toBe("a😁b");
    const vector = core.vector();
    writeInline(text, [{ insert: "a😁b", attributes: { bold: {} } }]);
    expect(core.vector()).toBe(vector);
    writeInline(text, [{ insert: "a😁b" }]); expect(text.toDelta()).toEqual([{ insert: "a😁b" }]);
    core.destroy();
  });
  it("limits all retained blocks and URL size", () => {
    const core = seed("one"); firstText(core).format(0, 3, { link: { href: "https://x/" + "x".repeat(8_192) } });
    expect(() => core.projection()).toThrow("document_too_large"); core.destroy();
    const many = new DocumentCore();
    writeBlocks(many.document, { blocks: Array.from({ length: 8_001 }, (_, i) => ({ id: String(i), type: "paragraph", parent: null, attrs: {}, text: [] })), removed: [], order: new Map() }, null);
    expect(() => many.projection()).toThrow("document_too_large");
    expect(many.projection(false).blocks).toHaveLength(8_001); many.destroy();
  });
  it("purges old tombstones to the count low-water mark without expiring recovery data", () => {
    const core = new DocumentCore();
    const blocks: BlockInput[] = Array.from({ length: 6_001 }, (_, i) => ({ id: String(i), type: "paragraph", parent: null, attrs: {}, text: [{ insert: "x" }] }));
    writeBlocks(core.document, { blocks, removed: [], order: new Map() }, null);
    writeBlocks(core.document, { blocks: [], removed: blocks.slice(0, 2_000).map((block) => block.id), order: new Map() }, null);
    core.purgeDeletedBlocks(0);
    expect(blockMap(core.document).size).toBe(5_000); expect(core.projection().blocks).toHaveLength(4_001); core.destroy();
  });
  it("uses deterministic cycle layout without modifying canonical parents", () => {
    const core = new DocumentCore();
    writeBlocks(core.document, { blocks: [
      { id: "a", type: "bulletList", attrs: {}, parent: "j" }, { id: "b", type: "bulletList", attrs: {}, parent: "i" },
      { id: "i", type: "listItem", attrs: {}, parent: "a" }, { id: "j", type: "listItem", attrs: {}, parent: "b" },
      { id: "p", type: "paragraph", attrs: {}, parent: "i", text: [{ insert: "p" }] }, { id: "q", type: "heading", attrs: { level: 2 }, parent: "j", text: [{ insert: "q" }] },
    ], removed: [], order: new Map([["a", ["i"]], ["i", ["p", "b"]], ["b", ["j"]], ["j", ["q", "a"]]]) }, null);
    expect(blockLayout(core.document)[0]?.id).toBe("a"); expect(core.projection().text).toBe("p\nq");
    expect(blockMap(core.document).get("a")!.get("parent")).toBe("j"); core.destroy();
  });
});

it("pastes blank lines as empty paragraphs without doubling HTML blank lines", () => {
  const schema = getSchema([StarterKit]), paragraphs = (fragment: Fragment) => {
    const lines: string[] = []; fragment.forEach((node) => lines.push(node.content.content.map((child) => child.isText ? child.text : "⏎").join(""))); return lines;
  };
  expect(paragraphs(pastedTextSlice("一\n\n三\r\n\r\n\r\n六", schema, []).content)).toEqual(["一", "", "三", "", "", "六"]);
  // `<p>a</p><br><p>b</p>` parses the middle blank line as a paragraph holding only a break.
  const p = (...content: Node[]) => schema.nodes.paragraph!.create(null, content);
  const pasted = Fragment.from([p(schema.text("a")), p(schema.nodes.hardBreak!.create()), p(schema.text("b"), schema.nodes.hardBreak!.create(), schema.text("c"))]);
  expect(paragraphs(withoutTrailingBreaks(pasted))).toEqual(["a", "", "b⏎c"]);
  const item = schema.nodes.listItem!.create(null, p(schema.text("nested"), schema.nodes.hardBreak!.create()));
  const list = schema.nodes.bulletList!.create(null, item), rule = schema.nodes.horizontalRule!.create();
  const cleaned = withoutTrailingBreaks(Fragment.from([list, rule]));
  expect(cleaned.firstChild!.firstChild!.firstChild!.toJSON()).toEqual(p(schema.text("nested")).toJSON());
  expect(cleaned.lastChild).toBe(rule);
});


it("hydrates without a shared placeholder and includes all prerequisite clocks", () => {
  const document = new Y.Doc(), hydration = new DocumentEditorHydration(document), shared = seed("remote");
  hydration.receive(decodeBinary(shared.checkpoint()));
  const vector = Y.encodeStateVector(document); firstText(document).insert(0, "B:");
  shared.apply(encodeBinary(hydration.captureLocalUpdate(Y.encodeStateAsUpdate(document, vector))));
  expect(shared.projection().text).toBe("B:remote");
  expect(shared.document.store.pendingStructs).toBeNull(); document.destroy(); shared.destroy();
});

it.each(["append failure", "v1 checkpoint", "v1 delta"])("retains the outbox and does not ACK on %s", async (failure) => {
  const pending: PendingDocumentUpdate[] = [], initial = seed("safe");
  let ack = 0;
  const session = new DocumentSession({ newID: id,
    append: async (update) => { if (failure === "append failure") throw new Error("disk full"); pending.push({ sequence: 1, update }); return 1; },
    pending: async () => pending, acknowledge: async () => { ack++; }, checkpoint: async () => {},
    exchange: async () => ({ generation: null, revision: 0, update: failure === "v1 checkpoint" ? fixture.v1.checkpoint : fixture.v1.append }),
  });
  if (failure === "append failure") await expect(session.accept(initial.checkpoint(), true)).rejects.toThrow("disk full");
  else { await session.accept(initial.checkpoint(), true); await expect(session.synchronize()).rejects.toThrow(); expect(pending).toHaveLength(1); }
  expect(ack).toBe(0); await session.close(); initial.destroy();
});

it("does not enqueue recovery for viewers and accepts concurrent over-limit remote state", async () => {
  const seed = new DocumentCore(fixture.checkpoint), recoveries: unknown[] = [];
  const session = new DocumentSession({ newID: id, append: async (_update, _local, recovery) => { if (recovery) recoveries.push(recovery); return 1; },
    pending: async () => [], acknowledge: async () => {}, checkpoint: async () => {}, exchange: async () => { throw new Error("unused"); },
  }, { checkpoint: seed.checkpoint(), generation: null, revision: 0 });
  await session.accept(fixture.deletionUpdate, false); expect(recoveries).toEqual([]);
  firstText(seed).insert(0, "x".repeat(2_000_001));
  await session.accept(seed.checkpoint(false), false);
  expect(session.core.projection(false).blocks.length).toBeGreaterThan(0);
  await session.close(); seed.destroy();
});

it.each(["acknowledged", "failed ACK", "restarted", "newer than ACK", "pending deletion"])("uses the current outbox for remote recovery (%s)", async (mode) => {
  const pending: PendingDocumentUpdate[] = [], recoveries: DocumentRecovery[] = [];
  let sequence = 0;
  const host: DocumentHost = { newID: id,
    append: async (update, local, recovery) => {
      sequence++;
      if (local) pending.push({ sequence, update });
      if (recovery) recoveries.push(recovery);
      return sequence;
    },
    pending: async () => [...pending], checkpoint: async () => {},
    exchange: async () => {
      if (mode === "newer than ACK") await session.accept(fixture.lateUpdate, true);
      return { generation: null, revision: 0, update: "AAA=" };
    },
    acknowledge: async (through) => {
      if (mode === "failed ACK") throw new Error("ACK failed");
      while (pending.length && pending[0]!.sequence <= through) pending.shift();
    },
  };
  let session = new DocumentSession(host);
  await session.accept(fixture.checkpoint, true);
  if (mode !== "newer than ACK") await session.accept(fixture.lateUpdate, true);
  if (mode === "pending deletion") await session.accept(fixture.retainedDeletionUpdate, true);
  else if (mode === "restarted") {
    const checkpoint = session.core.checkpoint();
    await session.close();
    session = new DocumentSession(host, { checkpoint, generation: null, revision: 0 });
  } else if (mode === "failed ACK") await expect(session.synchronize()).rejects.toThrow("ACK failed");
  else await session.synchronize();
  expect(pending.length > 0).toBe(mode !== "acknowledged");
  await session.accept(fixture.purgedCheckpoint, false);
  expect(recoveries).toHaveLength(mode === "acknowledged" ? 0 : 1);
  if (mode === "pending deletion") {
    expect(recoveries[0]?.reason).toBe("deleted");
    expect(recoveries[0]?.blocks.some((block) => block.text.includes("offline"))).toBe(true);
  }
  await session.accept(fixture.purgedCheckpoint, false);
  expect(recoveries).toHaveLength(mode === "acknowledged" ? 0 : 1);
  await session.close();
});

it("merges duplicate updates", () => {
  const core = seed("one");
  expect(new DocumentCore(mergeDocumentUpdates([core.checkpoint(), core.checkpoint()])).projection()).toEqual(core.projection()); core.destroy();
});
