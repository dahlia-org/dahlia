import { Extension, type Editor, type JSONContent } from "@tiptap/core";
import { Fragment, Mark, Slice, type Node, type Schema } from "@tiptap/pm/model";
import { NodeSelection, Plugin, Selection, TextSelection, type EditorState, type Transaction } from "@tiptap/pm/state";
import { dropPoint, ReplaceAroundStep } from "@tiptap/pm/transform";
import * as Y from "yjs";
import { blockLayout, blockMap, blockText, blockTypes, documentDepthLimit, documentURLLimit, renderedAttributes, rootOrder, totalBlockLimit, visibleBlockLimit, writeBlocks, type BlockChange, type BlockInput, type Inline, type LayoutNode } from "./blocks";
import { documentStateLimit, documentTextLimit, projectDocument, removedBlocks, type DocumentBlock } from "./core";

const remote = "dahliaDocumentRemote";
const adapters = new WeakMap<Y.Doc, DocumentBinding>();
interface Located { node: Node; pos: number; parent: string | null }
const nodeID = (node: Node | null | undefined): string | null => typeof node?.attrs.id === "string" ? node.attrs.id : null;
function indexBlocks(doc: Node): Map<string, Located> {
  const result = new Map<string, Located>();
  doc.descendants((node, pos, parent) => { const id = nodeID(node); if (blockTypes.includes(node.type.name as BlockInput["type"]) && id) result.set(id, { node, pos, parent: nodeID(parent) }); });
  return result;
}
function inline(node: Node): Inline[] {
  const parts: Inline[] = [];
  node.forEach((child) => parts.push({ insert: child.isText ? child.text! : { type: "hardBreak" }, attributes: Object.fromEntries(child.marks.map((mark) => [mark.type.name, mark.attrs])) }));
  return parts;
}
function changedTextBlock(before: Node, after: Node): Node | undefined {
  const start = before.content.findDiffStart(after.content), end = before.content.findDiffEnd(after.content);
  if (start === null || !end) return;
  const oldStart = before.resolve(start), newStart = after.resolve(start);
  if (oldStart.parent.isTextblock && newStart.parent.isTextblock && oldStart.parent.sameMarkup(newStart.parent)
    && before.resolve(Math.max(start, end.a)).parent === oldStart.parent && after.resolve(Math.max(start, end.b)).parent === newStart.parent) return newStart.parent;
}
function blockInput(node: Node, parent: string | null): BlockInput {
  const attrs = { ...node.attrs }; delete attrs.id;
  return { id: nodeID(node)!, type: node.type.name as BlockInput["type"], attrs, parent, ...(node.isTextblock ? { text: inline(node) } : {}) };
}
function changes(before: Node, after: Node, doc: Y.Doc): BlockChange {
  const single = changedTextBlock(before, after);
  if (single && nodeID(single)) return { blocks: [blockInput(single, blockMap(doc).get(nodeID(single)!)!.get("parent") as string | null)], removed: [], order: new Map() };
  const old = indexBlocks(before), next = indexBlocks(after), blocks: BlockInput[] = [], order = new Map<string | null, string[]>();
  for (const [id, { node, parent }] of next) {
    const previous = old.get(id);
    if (previous?.node !== node || previous.parent !== parent) {
      blocks.push(blockInput(node, parent));
    }
  }
  const visit = (node: Node, previous?: Node) => {
    if (node.isTextblock || node === previous) return;
    const ids = node.content.content.map((child) => child.attrs.id as string);
    if (!previous || ids.join("\0") !== previous.content.content.map(nodeID).join("\0")) order.set(nodeID(node), ids);
    node.forEach((child) => visit(child, old.get(nodeID(child) ?? "")?.node));
  };
  visit(after, before);
  return { blocks, removed: [...old.keys()].filter((id) => !next.has(id)), order };
}

interface Stats { blocks: number; text: number; depth: number; valid: boolean }
const stats = new WeakMap<Node, Stats>();
function measure(node: Node): Stats {
  const cached = stats.get(node); if (cached) return cached;
  const result: Stats = { blocks: node.isBlock && node.type.name !== "doc" ? 1 : 0, text: node.isText ? node.text!.length : node.type.name === "hardBreak" ? 1 : 0, depth: 0, valid: true };
  for (const mark of node.marks) if (mark.type.name === "link" && (typeof mark.attrs.href !== "string" || mark.attrs.href.length > documentURLLimit || !/^(https?:|mailto:)/i.test(mark.attrs.href))) result.valid = false;
  node.forEach((child, _offset, i) => {
    const childStats = measure(child);
    result.blocks += childStats.blocks; result.text += childStats.text + (i && child.isBlock ? 1 : 0);
    result.depth = Math.max(result.depth, childStats.depth + (child.isBlock ? 1 : 0)); result.valid &&= childStats.valid;
  });
  stats.set(node, result); return result;
}

interface Bookmark { anchor?: Y.RelativePosition; head?: Y.RelativePosition; node?: string; fallback: number }
function bookmark(state: EditorState, doc: Y.Doc): Bookmark {
  const selection = state.selection;
  if (selection instanceof NodeSelection) return { node: nodeID(selection.node) ?? undefined, fallback: selection.from };
  const position = (pos: number) => {
    const resolved = state.doc.resolve(pos), id = nodeID(resolved.parent), block = id ? blockMap(doc).get(id) : undefined;
    return block?.get("text") instanceof Y.Text ? Y.createRelativePositionFromTypeIndex(blockText(block), resolved.parentOffset) : undefined;
  };
  return { anchor: position(selection.anchor), head: position(selection.head), fallback: selection.head };
}
function restoreSelection(tr: Transaction, saved: Bookmark | undefined, doc: Y.Doc): void {
  if (!saved) return;
  const nodes = indexBlocks(tr.doc), selected = saved.node ? nodes.get(saved.node) : undefined;
  if (selected && NodeSelection.isSelectable(selected.node)) { tr.setSelection(NodeSelection.create(tr.doc, selected.pos)); return; }
  const resolve = (relative: Y.RelativePosition | undefined) => {
    const absolute = relative ? Y.createAbsolutePositionFromRelativePosition(relative, doc) : null;
    if (!absolute) return undefined;
    for (const [id, block] of blockMap(doc)) if (block.get("text") === absolute.type) {
      const located = nodes.get(id); if (located) return located.pos + 1 + Math.min(absolute.index, located.node.content.size);
    }
    return undefined;
  };
  const anchor = resolve(saved.anchor), head = resolve(saved.head);
  tr.setSelection(anchor !== undefined && head !== undefined ? TextSelection.create(tr.doc, anchor, head)
    : Selection.near(tr.doc.resolve(Math.min(saved.fallback, tr.doc.content.size))));
}

export class DocumentBinding {
  private rendered!: Node;
  private readonly cache = new Map<string, { node: Node; children: Node[]; type: string }>();
  private readonly undoManager: Y.UndoManager;
  private selection?: Bookmark;
  private undoSelection?: Bookmark;
  private draft?: Y.Doc;
  private applying = false;
  private timer?: ReturnType<typeof setTimeout>;
  private size: number;
  constructor(readonly editor: Editor, readonly document: Y.Doc, private readonly onError: (message: string) => void, private readonly onRecovery: (blocks: DocumentBlock[]) => void) {
    if (adapters.has(document)) throw new Error("document_editor_already_attached");
    adapters.set(document, this);
    this.undoManager = new Y.UndoManager([blockMap(document), rootOrder(document)], { trackedOrigins: new Set([this]) });
    this.undoManager.on("stack-item-added", ({ stackItem }) => { stackItem.meta.set("selection", this.selection); });
    this.undoManager.on("stack-item-popped", ({ stackItem }) => { this.undoSelection = stackItem.meta.get("selection") as Bookmark | undefined; });
    this.size = Y.encodeStateAsUpdate(document).byteLength;
    document.on("beforeTransaction", this.beforeY);
    document.on("afterTransaction", this.afterY);
    blockMap(document).observeDeep(this.invalidate);
    editor.on("transaction", this.onTransaction);
  }
  initialize(): Node { this.rendered = this.build(this.editor.schema); return this.rendered; }
  private build(schema: Schema): Node {
    const visit = (layout: LayoutNode): Node => {
      const children = layout.children.map(visit), cached = this.cache.get(layout.id);
      if (cached && cached.type === layout.type && children.length === cached.children.length && children.every((node, i) => node === cached.children[i])) return cached.node;
      const content: Node[] = [];
      if (layout.block.get("text") instanceof Y.Text) for (const part of blockText(layout.block).toDelta() as Inline[]) {
        let marks: readonly Mark[] = [];
        for (const name of Object.keys(part.attributes ?? {}).sort()) marks = schema.marks[name]!.create(part.attributes![name] as Record<string, unknown>).addToSet(marks);
        content.push(typeof part.insert === "string" ? schema.text(part.insert, marks) : schema.nodes.hardBreak!.create(null, null, marks));
      }
      const node = schema.nodes[layout.type]!.create({ ...renderedAttributes(layout.type, layout.block), id: layout.id }, children.length ? children : content);
      this.cache.set(layout.id, { node, children, type: layout.type }); return node;
    };
    const content = blockLayout(this.document).map(visit);
    return schema.nodes.doc!.create(null, content.length ? content : schema.nodes.paragraph!.create({ id: null }));
  }
  private invalidate = (events: Y.YEvent<Y.AbstractType<unknown>>[]) => {
    for (const event of events) {
      if (event.path.length) this.cache.delete(String(event.path[0]));
      else if (event instanceof Y.YMapEvent) for (const key of event.keysChanged) if (typeof key === "string") this.cache.delete(key);
    }
  };
  private beforeY = (transaction: Y.Transaction) => {
    if (!this.rendered || transaction.origin === this) return;
    this.selection = bookmark(this.editor.state, this.document);
    if (this.composing() && !this.draft) {
      this.draft = new Y.Doc(); Y.applyUpdate(this.draft, Y.encodeStateAsUpdate(this.document));
    }
  };
  private afterY = (transaction: Y.Transaction) => {
    if (transaction.origin === this) return;
    this.size = Y.encodeStateAsUpdate(this.document).byteLength;
    if (!this.composing()) this.receive();
  };
  private composing(): boolean { try { return this.editor.view.composing; } catch { return false; } }
  flush = () => {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { if (!this.composing()) { this.draft?.destroy(); this.draft = undefined; this.receive(); } }, 50);
  };
  private receive(): void {
    if (!this.rendered || this.applying) return;
    const desired = this.build(this.editor.schema), current = this.editor.state.doc;
    if (current.eq(desired)) { this.rendered = current; return; }
    const tr = this.editor.state.tr, start = current.content.findDiffStart(desired.content);
    if (start !== null) {
      const end = current.content.findDiffEnd(desired.content)!;
      const overlap = start - Math.min(end.a, end.b);
      try { tr.replace(start, end.a + Math.max(0, overlap), desired.slice(start, end.b + Math.max(0, overlap))); } catch { /* Structural boundary: replace the whole projection below. */ }
      if (!tr.doc.eq(desired)) tr.replaceWith(0, tr.doc.content.size, desired.content);
    }
    restoreSelection(tr, this.undoSelection ?? this.selection, this.document);
    tr.setMeta(remote, true).setMeta("addToHistory", false);
    this.applying = true;
    try { this.editor.view.dispatch(tr); this.rendered = this.editor.state.doc; }
    finally { this.applying = false; this.undoSelection = undefined; }
  }
  private onTransaction = ({ transaction }: { transaction: Transaction }) => {
    if (transaction.getMeta(remote) || this.applying) { this.rendered = this.editor.state.doc; return; }
    if (!this.editor.isEditable || this.rendered.eq(this.editor.state.doc)) return;
    const target = this.draft ?? this.document, change = changes(this.rendered, this.editor.state.doc, target);
    try {
      if (transaction.getMeta("dahliaMove")) this.undoManager.stopCapturing();
      if (this.draft) {
        const vector = Y.encodeStateVector(target); writeBlocks(target, change, this);
        const before = projectDocument(target, false);
        Y.applyUpdate(this.document, Y.encodeStateAsUpdate(target, vector), this);
        // A purged parent discards late Yjs text before update observers can read it.
        // Hand the changed draft bodies to the host before flush/detach destroys them.
        const changed = new Set(change.blocks.map((block) => block.id));
        const lost = removedBlocks(before, projectDocument(this.document, false)).filter((block) => changed.has(block.id));
        if (lost.length) this.onRecovery(lost);
      } else writeBlocks(target, change, this);
      this.rendered = this.editor.state.doc;
      if (transaction.getMeta("dahliaMove")) this.undoManager.stopCapturing();
    } catch (error) { this.onError(error instanceof Error ? error.message : "invalid_document_update"); this.receive(); }
  };
  filter(tr: Transaction): boolean {
    if (tr.getMeta(remote) || !tr.docChanged) return true;
    if (!this.editor.isEditable) return false;
    this.selection = bookmark(this.editor.state, this.draft ?? this.document);
    const next = measure(tr.doc), previous = measure(this.editor.state.doc);
    const single = changedTextBlock(this.editor.state.doc, tr.doc), existing = blockMap(this.document);
    let added = 0;
    if (!single || !nodeID(single)) {
      const old = indexBlocks(this.editor.state.doc), seen = new Set<string>();
      tr.doc.descendants((node) => {
        if (!node.isBlock) return;
        const id = nodeID(node);
        if (!id || !old.has(id) || seen.has(id)) added++;
        if (id) seen.add(id);
      });
    }
    const exceeds = !next.valid || next.depth > documentDepthLimit || (next.blocks > visibleBlockLimit && next.blocks >= previous.blocks)
      || (next.text > documentTextLimit && next.text >= previous.text) || (existing.size + added > totalBlockLimit && added > 0);
    // Conservative UTF-8 and item/format overhead. Remeasure only near the ceiling.
    const start = tr.before.content.findDiffStart(tr.doc.content) ?? 0, end = tr.before.content.findDiffEnd(tr.doc.content);
    const slice = end ? tr.doc.slice(start, Math.max(start, end.b)) : null;
    let runs = 0; slice?.content.descendants(() => { runs++; });
    const growth = slice ? new TextEncoder().encode(JSON.stringify(slice.toJSON())).byteLength + (added + runs) * 512 + tr.steps.length * 128 : 0;
    if (this.size + growth > documentStateLimit * .9) this.size = Y.encodeStateAsUpdate(this.document).byteLength;
    if (exceeds || this.size + growth > documentStateLimit) { this.onError("document_too_large"); return false; }
    this.size += growth;
    return true;
  }
  history(redo: boolean): boolean {
    if (!this.editor.isEditable) return false;
    if (!(redo ? this.undoManager.redoStack : this.undoManager.undoStack).length) return false;
    // History can restore content over the limit after concurrent remote additions.
    // Preview only these infrequent operations; never allocate clocks in the live doc on rejection.
    const preview = new Y.Doc({ gc: false });
    let history: Y.UndoManager | undefined;
    try {
      Y.applyUpdate(preview, Y.encodeStateAsUpdate(this.document));
      preview.clientID = this.document.clientID;
      // Redone links are local Undo metadata, not part of a Yjs encoded update.
      preview.transact((transaction) => {
        for (const structs of this.document.store.clients.values()) for (const item of structs) {
          if (item instanceof Y.Item && item.redone) Y.getItemCleanStart(transaction, item.id).redone = item.redone;
        }
      });
      history = new Y.UndoManager([blockMap(preview), rootOrder(preview)]);
      history.undoStack = this.undoManager.undoStack.slice();
      history.redoStack = this.undoManager.redoStack.slice();
      if (redo) history.redo(); else history.undo();
      projectDocument(preview);
      if (Y.encodeStateAsUpdate(preview).byteLength > documentStateLimit) throw new Error("document_too_large");
    } catch (error) {
      this.onError(error instanceof Error ? error.message : "invalid_document_update"); return false;
    } finally { history?.destroy(); preview.destroy(); }
    this.applying = true;
    try { if (redo) this.undoManager.redo(); else this.undoManager.undo(); }
    finally { this.applying = false; }
    this.receive(); return true;
  }
  destroy(): void {
    clearTimeout(this.timer); this.draft?.destroy();
    this.document.off("beforeTransaction", this.beforeY); this.document.off("afterTransaction", this.afterY);
    blockMap(this.document).unobserveDeep(this.invalidate); this.undoManager.destroy();
    this.editor.off("transaction", this.onTransaction); adapters.delete(this.document);
  }
}

/** Restore IDs dropped by setNodeMarkup (including paragraph/heading conversions). */
function normalizeIDs(transactions: readonly Transaction[], oldState: EditorState, newState: EditorState, doc: Y.Doc): Transaction | undefined {
  if (!transactions.some((tr) => tr.docChanged) || transactions.some((tr) => tr.getMeta(remote))) return;
  if (nodeID(changedTextBlock(oldState.doc, newState.doc))) return;
  const tr = newState.tr, old = indexBlocks(oldState.doc), seen = new Set<string>();
  for (let ti = 0; ti < transactions.length; ti++) {
    const transaction = transactions[ti]!;
    transaction.steps.forEach((step, si) => {
      if (!(step instanceof ReplaceAroundStep) || !(step.toJSON() as { structure?: boolean }).structure || step.insert !== 1 || step.slice.openStart || step.slice.openEnd || step.slice.content.childCount !== 1) return;
      const original = transaction.docs[si]!.nodeAt(step.from);
      if (!original?.attrs.id || step.gapFrom !== step.from + 1 || step.gapTo !== step.from + original.nodeSize - 1) return;
      let pos = transaction.mapping.slice(si + 1).map(step.from);
      for (let j = ti + 1; j < transactions.length; j++) pos = transactions[j]!.mapping.map(pos);
      const node = tr.doc.nodeAt(pos);
      if (node && nodeID(node) !== nodeID(original)) tr.setNodeMarkup(pos, undefined, { ...node.attrs, id: nodeID(original) });
    });
  }
  tr.doc.descendants((node, pos) => {
    if (!blockTypes.includes(node.type.name as BlockInput["type"])) return;
    let id = node.attrs.id as string | null;
    if (!id || seen.has(id) || (!old.has(id) && blockMap(doc).has(id))) {
      id = crypto.randomUUID(); tr.setNodeMarkup(pos, undefined, { ...node.attrs, id });
    }
    seen.add(id);
  });
  return tr.steps.length ? tr.setStoredMarks(newState.storedMarks) : undefined;
}

export function moveBlock(editor: Editor, id: string, target: number): boolean {
  if (!editor.isEditable) return false;
  const source = indexBlocks(editor.state.doc).get(id); if (!source) return false;
  if (target >= source.pos && target <= source.pos + source.node.nodeSize) return false;
  const point = dropPoint(editor.state.doc, target, new Slice(Fragment.from(source.node), 0, 0));
  if (point === null) return false;
  const tr = editor.state.tr.delete(source.pos, source.pos + source.node.nodeSize);
  tr.replaceRangeWith(tr.mapping.map(point), tr.mapping.map(point), source.node).setMeta("dahliaMove", true);
  const moved = indexBlocks(tr.doc).get(id);
  if (moved) {
    const selection = editor.state.selection;
    if (selection instanceof NodeSelection) tr.setSelection(NodeSelection.create(tr.doc, moved.pos));
    else if (selection.from >= source.pos && selection.to <= source.pos + source.node.nodeSize) tr.setSelection(TextSelection.create(tr.doc, moved.pos + selection.anchor - source.pos, moved.pos + selection.head - source.pos));
  }
  editor.view.dispatch(tr); return true;
}
function moveSibling(editor: Editor, direction: number): boolean {
  const pos = editor.state.selection.$from;
  let depth = pos.depth;
  while (depth > 1 && pos.node(depth).type.name !== "listItem") depth--;
  if (!depth) return false;
  const node = pos.node(depth), parent = pos.node(depth - 1), index = pos.index(depth - 1), other = parent.maybeChild(index + direction);
  if (!other) return false;
  const from = pos.before(depth);
  return moveBlock(editor, nodeID(node)!, direction < 0 ? from - other.nodeSize : from + node.nodeSize + other.nodeSize);
}
declare module "@tiptap/core" { interface Commands<ReturnType> { dahliaHistory: { undo: () => ReturnType; redo: () => ReturnType } } }
export const DocumentAdapter = Extension.create<{ document: Y.Doc; onError: (message: string) => void; onRecovery: (blocks: DocumentBlock[]) => void }, { binding: DocumentBinding }>({
  name: "dahliaDocument", priority: 11000,
  addOptions: () => ({ document: new Y.Doc(), onError: () => {}, onRecovery: () => {} }),
  onBeforeCreate() {
    projectDocument(this.options.document, false);
    this.storage.binding = new DocumentBinding(this.editor, this.options.document, this.options.onError, this.options.onRecovery);
    this.editor.options.content = this.storage.binding.initialize().toJSON() as JSONContent;
  },
  addProseMirrorPlugins() {
    return [new Plugin({ filterTransaction: (tr) => this.storage.binding.filter(tr),
      appendTransaction: (transactions, oldState, newState) => normalizeIDs(transactions, oldState, newState, this.options.document),
      props: { handleDOMEvents: { compositionend: () => { this.storage.binding.flush(); return false; }, blur: () => { this.storage.binding.flush(); return false; } } },
    })];
  },
  addCommands() { return { undo: () => ({ tr, dispatch }) => { tr.setMeta("preventDispatch", true); return dispatch ? this.storage.binding.history(false) : true; }, redo: () => ({ tr, dispatch }) => { tr.setMeta("preventDispatch", true); return dispatch ? this.storage.binding.history(true) : true; } }; },
  addKeyboardShortcuts() { return { "Mod-z": () => this.editor.commands.undo(), "Mod-Shift-z": () => this.editor.commands.redo(), "Mod-y": () => this.editor.commands.redo(), "Mod-Shift-ArrowUp": () => moveSibling(this.editor, -1), "Mod-Shift-ArrowDown": () => moveSibling(this.editor, 1) }; },
  onDestroy() { this.storage.binding.destroy(); },
});
