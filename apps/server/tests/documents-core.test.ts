import { DocumentEditorHydration } from "../src/documents/editor";
import fixture from "../../desktop/Tests/DahliaTests/Fixtures/documents.json";
import { describe, expect, it } from "vitest";
import * as Y from "yjs";
import { DocumentCore, decodeBinary, documentFragment, documentStateLimit, encodeBinary, mergeDocumentUpdates, removedBlocks } from "../src/documents/core";
import { DocumentSession, type PendingDocumentUpdate } from "../src/documents/session";
import { run as runNativeDocument } from "../src/documents/native-core";

const id = () => crypto.randomUUID();
const paragraph = (core: DocumentCore) => core.document.getXmlFragment(documentFragment).get(0) as Y.XmlElement;
const text = (core: DocumentCore) => paragraph(core).get(0) as Y.XmlText;

describe("portable document core", () => {
  it("uses the same fixture in Node, Workers and JavaScriptCore", () => {
    const core = new DocumentCore(fixture.checkpoint);
    for (const update of fixture.updates) core.apply(update);
    expect(core.projection()).toEqual({ text: fixture.text, blocks: fixture.blocks });
    core.destroy();
  });
  it("round trips bytes without platform base64 APIs", () => {
    for (let count = 0; count < 260; count++) {
      const bytes = Uint8Array.from({ length: count }, (_, i) => i % 256);
      expect(encodeBinary(bytes)).toBe(Buffer.from(bytes).toString("base64"));
      expect(decodeBinary(encodeBinary(bytes))).toEqual(bytes);
    }
    expect(() => decodeBinary("bad!")).toThrow("invalid_document_update");
    expect(() => decodeBinary(Buffer.alloc(documentStateLimit + 1).toString("base64"))).toThrow("invalid_document_update");
  });
  it("preserves literal legacy text including Markdown, CRLF, blank lines and trailing newline", () => {
    const core = new DocumentCore();
    const legacy = "# 見出しではない\r\n\n- メモ\n";
    core.insertText(legacy, id);
    expect(new DocumentCore(core.checkpoint()).projection().text).toBe(legacy);
  });
  it("converges on concurrent insertion in the same paragraph, reverse and duplicate delivery", () => {
    const initial = new DocumentCore(); initial.insertText("会議", id);
    const a = new DocumentCore(initial.checkpoint()), b = new DocumentCore(initial.checkpoint());
    text(a).insert(1, "A"); text(b).insert(1, "B");
    const ua = a.difference(initial.vector()), ub = b.difference(initial.vector());
    a.apply(ub); a.apply(ua); b.apply(ua); b.apply(ub);
    expect(a.projection()).toEqual(b.projection());
    expect(a.projection().text).toMatch(/会(?:AB|BA)議/);
    const restarted = new DocumentCore(initial.checkpoint());
    restarted.apply(mergeDocumentUpdates([ub, ua, ua]));
    expect(restarted.projection()).toEqual(a.projection());
  });
  it("retains edited content when another client deletes its paragraph; recovery inserts with a new ID", () => {
    const a = new DocumentCore(); a.insertText("before", id);
    const b = new DocumentCore(a.checkpoint());
    text(a).insert(6, " private edit");
    const before = a.projection();
    b.document.getXmlFragment(documentFragment).delete(0, 1);
    a.apply(b.checkpoint());
    const lost = removedBlocks(before, a.projection());
    expect(lost.map((block) => block.text)).toEqual(["before private edit"]);
    a.restore(lost, id);
    expect(a.projection().text).toBe("before private edit");
    expect(a.projection().blocks[0]!.id).not.toBe(lost[0]!.id);
  });
  it("repairs duplicate block IDs once and distributes that decision", () => {
    const a = new DocumentCore(); a.insertText("one\ntwo", () => "duplicate");
    const b = new DocumentCore(a.checkpoint());
    b.apply(a.repairBlockIDs(id));
    expect(a.projection()).toEqual(b.projection());
    expect(new Set(a.projection().blocks.map((block) => block.id)).size).toBe(2);
  });
  it("does not apply or acknowledge edits when durable append fails", async () => {
    const seed = new DocumentCore(); seed.insertText("safe", id);
    const pending: PendingDocumentUpdate[] = [];
    const session = new DocumentSession({ newID: id,
      append: async () => { throw new Error("disk full"); }, pending: async () => pending,
      acknowledge: async () => { throw new Error("unexpected ack"); },
      checkpoint: async () => {}, exchange: async () => { throw new Error("unexpected request"); },
    });
    await expect(session.accept(seed.checkpoint(), true)).rejects.toThrow("disk full");
    expect(session.core.projection().text).toBe("");
  });
});

it("replaces only an untouched editor placeholder with the first shared content", () => {
  const document = new Y.Doc(), hydration = new DocumentEditorHydration(document);
  const fragment = document.getXmlFragment("content"); fragment.insert(0, [new Y.XmlElement("paragraph")]);
  const shared = new DocumentCore(); shared.insertText("remote", () => "remote-block");
  hydration.receive(decodeBinary(shared.checkpoint()));
  expect(fragment.length).toBe(1);
  let emitted: Uint8Array = new Uint8Array();
  document.on("update", (update: Uint8Array) => { emitted = update; });
  const text = (fragment.get(0) as Y.XmlElement).get(0) as Y.XmlText;
  text.insert(0, "B:");
  shared.apply(encodeBinary(hydration.captureLocalUpdate(emitted)));
  expect(shared.projection().text).toBe("B:remote");
  expect(shared.document.store.pendingStructs).toBeNull();
  text.insert(text.length, ":again");
  shared.apply(encodeBinary(hydration.captureLocalUpdate(emitted)));
  expect(shared.projection().text).toBe("B:remote:again");
  expect(fragment.toString()).toContain("remote");
  hydration.receive(decodeBinary(shared.checkpoint()));
  expect(fragment.length).toBe(1);
  const edited = new Y.Doc(), preserve = new DocumentEditorHydration(edited);
  edited.getXmlFragment("content").insert(0, [new Y.XmlElement("paragraph")]); preserve.edited();
  preserve.receive(decodeBinary(shared.checkpoint()));
  expect(edited.getXmlFragment("content").length).toBe(2);
  document.destroy(); edited.destroy(); shared.destroy();
});

it("does not enqueue write-only recovery from a viewer's remote merge", async () => {
  const seed = new DocumentCore(); seed.insertText("shared", id);
  const recoveries: unknown[] = [];
  const session = new DocumentSession({ newID: id,
    append: async (_update, _local, recovery) => { if (recovery) recoveries.push(recovery); return 1; },
    pending: async () => [], acknowledge: async () => {}, checkpoint: async () => {}, exchange: async () => { throw new Error("unused"); },
  }, { checkpoint: seed.checkpoint(), generation: null, revision: 0 });
  seed.document.getXmlFragment(documentFragment).delete(0, 1);
  await session.accept(seed.checkpoint(), false);
  expect(recoveries).toEqual([]); expect(session.core.projection().text).toBe("");
  await session.close(); seed.destroy();
});

it("includes pre-observer editor normalization when opened with existing content", () => {
  const shared = new DocumentCore(); shared.insertText("existing", id);
  const editor = new Y.Doc(); Y.applyUpdate(editor, decodeBinary(shared.checkpoint()));
  const hydration = new DocumentEditorHydration(editor);
  const text = (editor.getXmlFragment(documentFragment).get(0) as Y.XmlElement).get(0) as Y.XmlText;
  text.insert(0, "before-observer:");
  let emitted: Uint8Array = new Uint8Array();
  editor.on("update", (update: Uint8Array) => { emitted = update; });
  text.insert(text.length, ":first-edit");
  shared.apply(encodeBinary(hydration.captureLocalUpdate(emitted)));
  expect(shared.projection().text).toBe("before-observer:existing:first-edit");
  expect(shared.document.store.pendingStructs).toBeNull();
  shared.destroy(); editor.destroy();
});

it("publishes monotonic versions inside the durable queue even when a local edit arrives during remote append", async () => {
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>((resolve) => { enter = resolve; });
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  const versions: { generation: string | null; revision: number }[] = [];
  let sequence = 0;
  const session = new DocumentSession({ newID: id,
    append: async () => { if (!sequence) { enter(); await blocked; } return ++sequence; },
    pending: async () => [], acknowledge: async () => {}, exchange: async () => { throw new Error("unused"); },
    checkpoint: async ({ generation, revision }) => { versions.push({ generation, revision }); },
  });
  const remote = session.accept("AAA=", false, { generation: "first", revision: 8 });
  await entered;
  const local = session.accept("AAA=", true);
  release(); await Promise.all([remote, local]);
  await session.accept("AAA=", false, { generation: "first", revision: 3 });
  expect(versions).toEqual(Array.from({ length: 3 }, () => ({ generation: "first", revision: 8 })));
  await expect(session.accept("AAA=", false, { generation: "replaced", revision: 1 })).rejects.toThrow("document_generation_changed");
  expect(sequence).toBe(3);
  await session.close();
});


it("never serializes an oversized native checkpoint and can rebuild its durable log after a corrective deletion", () => {
  const editor = new Y.Doc(), root = editor.getXmlFragment(documentFragment);
  const insert = () => {
    const paragraph = new Y.XmlElement("paragraph"), text = new Y.XmlText();
    paragraph.setAttribute("id", id());
    text.insert(0, "linked", { link: { href: `https://example.invalid/${"x".repeat(documentStateLimit / 2)}` } });
    paragraph.insert(0, [text]); root.insert(root.length, [paragraph]);
  };
  try {
    insert();
    const checkpoint = encodeBinary(Y.encodeStateAsUpdate(editor));
    const before = Y.encodeStateVector(editor); insert();
    const addition = encodeBinary(Y.encodeStateAsUpdate(editor, before));
    expect(() => runNativeDocument(JSON.stringify({ checkpoint, updates: [addition] }))).toThrow("document_too_large");
    const oversized = Y.encodeStateVector(editor); root.delete(1, 1);
    const deletion = encodeBinary(Y.encodeStateAsUpdate(editor, oversized));
    const restored = JSON.parse(runNativeDocument(JSON.stringify({ checkpoint, updates: [addition, deletion] }))) as { checkpoint: string };
    const valid = new DocumentCore(restored.checkpoint);
    try { expect(valid.projection().text).toBe("linked"); expect(valid.document.store.pendingStructs).toBeNull(); }
    finally { valid.destroy(); }
  } finally { editor.destroy(); }
});
