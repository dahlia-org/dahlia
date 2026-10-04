import { Editor, Extension, type EditorOptions } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import UniqueID from "@tiptap/extension-unique-id";
import { Fragment, Slice, type Mark, type Node, type ResolvedPos, type Schema } from "@tiptap/pm/model";
import { NodeSelection, Plugin } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";
import * as Y from "yjs";
import { projectDocument, removedBlocks, type DocumentBlock } from "./core";
import { DocumentAdapter, moveBlock } from "./binding";
export { moveBlock } from "./binding";

export function documentEditorOptions(document: Y.Doc, editable: boolean, placeholder: string, onError: (message: string) => void = () => {}, onRecovery: (blocks: DocumentBlock[]) => void = () => {}): Partial<EditorOptions> {
  return {
    editable,
    extensions: [StarterKit.configure({ undoRedo: false, trailingNode: false, codeBlock: false, blockquote: false, horizontalRule: false, dropcursor: { width: 2, color: false },
      link: { openOnClick: false, protocols: ["http", "https", "mailto"], isAllowedUri: (url) => /^(https?:|mailto:)/i.test(url) } }),
    DocumentAdapter.configure({ document, onError, onRecovery }),
    UniqueID.configure({ types: ["paragraph", "heading", "bulletList", "orderedList", "listItem"],
      updateDocument: false }),
    PreserveBlankLines, BlockHandle],
    editorProps: { attributes: { class: "dahlia-document", role: "textbox", "aria-multiline": "true", "aria-placeholder": placeholder } },
  };
}
export function mountDocumentEditor(element: HTMLElement, document: Y.Doc, editable: boolean, placeholder: string, onError?: (message: string) => void, onRecovery?: (blocks: DocumentBlock[]) => void): Editor {
  return new Editor({ ...documentEditorOptions(document, editable, placeholder, onError, onRecovery), element });
}

/** One paragraph per line; ProseMirror's default parser collapses blank lines. */
export function pastedTextSlice(text: string, schema: Schema, marks: readonly Mark[]): Slice {
  return Slice.maxOpen(Fragment.from(text.replace(/\r\n?/g, "\n").split("\n")
    .map((line) => schema.nodes.paragraph!.create(null, line ? schema.text(line, marks) : null))));
}

/**
 * A `<br>` between blocks (Google Docs, VS Code) means one blank line, but parses as a paragraph
 * holding a break, which ProseMirror draws two lines tall. It already ignores a block's final `<br>`.
 */
export function withoutTrailingBreaks(fragment: Fragment): Fragment {
  const nodes: Node[] = [];
  fragment.forEach((node) => {
    if (node.isTextblock && node.lastChild?.type.name === "hardBreak") {
      nodes.push(node.copy(node.content.cut(0, node.content.size - 1)));
    } else if (!node.isTextblock && !node.isLeaf) {
      nodes.push(node.copy(withoutTrailingBreaks(node.content)));
    } else {
      nodes.push(node);
    }
  });
  return Fragment.from(nodes);
}

const PreserveBlankLines = Extension.create({
  name: "dahliaPreserveBlankLines",
  addProseMirrorPlugins() {
    return [new Plugin({ props: {
      clipboardTextParser: (text, $context) => pastedTextSlice(text, $context.doc.type.schema, $context.marks()),
      // A drag within the editor moves document content as is, including a deliberate final break.
      transformPasted: (slice, view) => view.dragging ? slice : new Slice(withoutTrailingBreaks(slice.content), slice.openStart, slice.openEnd),
    } })];
  },
});

/** The block a handle moves: always a top-level block, so a list moves as a whole. */
function draggableBlock($pos: ResolvedPos): number | null {
  if ($pos.depth > 0) return $pos.before(1);
  return $pos.nodeAfter ? $pos.pos : $pos.nodeBefore ? $pos.pos - $pos.nodeBefore.nodeSize : null;
}

/** Resolve the ID again at drop: remote edits may have changed the source position. */
class BlockHandleView {
  private readonly handle: HTMLElement;
  private readonly indicator: HTMLElement;
  private host!: HTMLElement;
  private pos: number | null = null;
  private draggedID: string | null = null;
  constructor(private readonly view: EditorView, private readonly editor: Editor) {
    this.setHost(view.dom.parentElement!);
    this.handle = view.dom.ownerDocument.createElement("div");
    this.handle.className = "dahlia-block-handle";
    this.handle.draggable = true;
    this.handle.setAttribute("aria-hidden", "true");
    this.handle.innerHTML = '<svg viewBox="0 0 10 16" width="10" height="16" fill="currentColor">'
      + [3, 8, 13].map((y) => `<circle cx="2.5" cy="${y}" r="1.5"/><circle cx="7.5" cy="${y}" r="1.5"/>`).join("") + "</svg>";
    this.handle.addEventListener("dragstart", this.dragStart);
    this.handle.addEventListener("dragend", this.dragEnd);
    this.indicator = view.dom.ownerDocument.createElement("div");
    this.indicator.className = "dahlia-block-drop-indicator";
  }
  update(view: EditorView, previous: { doc: Node }) {
    // React's EditorContent reparents the view after Tiptap creates it.
    this.setHost(view.dom.parentElement!);
    // A stale position could move the wrong block after typing or a remote change.
    if (view.state.doc !== previous.doc) this.hide();
  }
  private setHost(host: HTMLElement) {
    if (this.host === host) return;
    this.releaseHost();
    this.host = host;
    host.classList.add("dahlia-document-host");
    host.addEventListener("mousemove", this.hover);
    host.addEventListener("mouseleave", this.leave);
  }
  private releaseHost() {
    if (!this.host) return;
    this.host.removeEventListener("mousemove", this.hover);
    this.host.removeEventListener("mouseleave", this.leave);
    this.host.classList.remove("dahlia-document-host");
  }
  /**
   * Track a handle drag by pointer coordinates across the whole host, including the handle gutter.
   * WebKit accepts a drop on the first event over a new element (dragenter) and reports dragleave without
   * a relatedTarget, so element boundaries must neither reject the drop nor hide the indicator.
   * Capture at the document runs before the drop cursor, which would point inside a list.
   */
  private listenToDrag(listen: boolean) {
    const document = this.view.dom.ownerDocument;
    for (const [type, listener] of [["dragenter", this.dragOver], ["dragover", this.dragOver], ["dragleave", this.dragLeave], ["drop", this.drop]] as const) {
      if (listen) document.addEventListener(type, listener, true); else document.removeEventListener(type, listener, true);
    }
  }
  destroy() {
    this.releaseHost();
    this.listenToDrag(false);
    this.handle.remove(); this.indicator.remove();
  }
  private hide() { this.pos = null; this.handle.style.display = "none"; }
  /** The document position on the pointer's row, so the gutter resolves like the text beside it. */
  private posAtRow(event: MouseEvent): number | null {
    const bounds = this.view.dom.getBoundingClientRect();
    return this.view.posAtCoords({ left: Math.min(Math.max(event.clientX, bounds.left + 1), bounds.right - 1), top: event.clientY })?.pos ?? null;
  }
  private hover = (event: MouseEvent) => {
    const { view } = this;
    if (!view.editable || view.dragging) return this.hide();
    // The handle sits outside the top-level block's text; keep its resolved block.
    if (event.target instanceof globalThis.Node && this.handle.contains(event.target)) return;
    const hit = this.posAtRow(event);
    const pos = hit === null ? null : draggableBlock(view.state.doc.resolve(hit));
    const block = pos === null ? null : view.nodeDOM(pos);
    if (pos === null || !(block instanceof HTMLElement)) return this.hide();
    const box = block.getBoundingClientRect();
    if (event.clientY < box.top || event.clientY > box.bottom) return this.hide();
    const host = this.host;
    if (this.handle.parentElement !== host) host.appendChild(this.handle);
    this.pos = pos;
    this.handle.style.display = "flex";
    // Sit left of a list's bullets, and center on the first line of its first text block.
    let text = pos + 1;
    for (let node = view.state.doc.nodeAt(pos); node && !node.isTextblock; node = node.firstChild) text++;
    const line = view.coordsAtPos(text);
    const origin = host.getBoundingClientRect();
    this.handle.style.left = `${box.left - origin.left - this.handle.offsetWidth}px`;
    this.handle.style.top = `${(line.top + line.bottom - this.handle.offsetHeight) / 2 - origin.top}px`;
  };
  private leave = (event: MouseEvent) => {
    const next = event.relatedTarget;
    if (!(next instanceof globalThis.Node && (this.view.dom.contains(next) || this.handle.contains(next)))) this.hide();
  };
  private dragStart = (event: DragEvent) => {
    const { view, pos } = this;
    if (pos === null || !event.dataTransfer) return event.preventDefault();
    const selection = NodeSelection.create(view.state.doc, pos);
    this.draggedID = selection.node.attrs.id as string;
    view.dispatch(view.state.tr.setSelection(selection));
    const { dom, text, slice } = view.serializeForClipboard(selection.content());
    event.dataTransfer.clearData();
    event.dataTransfer.setData("text/html", dom.innerHTML);
    event.dataTransfer.setData("text/plain", text);
    event.dataTransfer.effectAllowed = "move";
    const block = view.nodeDOM(pos);
    if (block instanceof HTMLElement) event.dataTransfer.setDragImage(block, 0, 0);
    // The drop handler deletes `node` and inserts `slice` at the drop point (Alt copies instead).
    view.dragging = { slice, move: true, node: selection } as EditorView["dragging"];
    this.listenToDrag(true);
  };
  private inHost(event: DragEvent): boolean {
    const box = this.host.getBoundingClientRect();
    return event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom;
  }
  /**
   * The gap before the first top-level block whose vertical middle is below the pointer, and its position.
   * Only the pointer's height counts, so text, list bullets, and the handle gutter resolve alike.
   */
  private dropTarget(event: DragEvent): { pos: number; top: number } {
    const { view } = this, doc = view.state.doc, starts: number[] = [];
    doc.forEach((_node, offset) => starts.push(offset));
    const rect = (index: number) => (view.nodeDOM(starts[index]!) as HTMLElement).getBoundingClientRect();
    let index = 0, end = starts.length;
    while (index < end) {
      const middle = (index + end) >> 1, box = rect(middle);
      if (event.clientY < (box.top + box.bottom) / 2) end = middle; else index = middle + 1;
    }
    const above = index > 0 ? rect(index - 1).bottom : undefined, below = index < starts.length ? rect(index).top : undefined;
    const top = above !== undefined && below !== undefined ? (above + below) / 2 : (above ?? below)!;
    return { pos: index < starts.length ? starts[index]! : doc.content.size, top };
  }
  private dragOver = (event: DragEvent) => {
    if (!this.inHost(event)) return this.indicator.remove();
    event.preventDefault(); event.stopImmediatePropagation();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    const target = this.dropTarget(event);
    if (this.indicator.parentElement !== this.host) this.host.appendChild(this.indicator);
    const origin = this.host.getBoundingClientRect(), bounds = this.view.dom.getBoundingClientRect();
    this.indicator.style.left = `${bounds.left - origin.left}px`;
    this.indicator.style.width = `${bounds.width}px`;
    this.indicator.style.top = `${target.top - origin.top - this.indicator.offsetHeight / 2}px`;
  };
  private dragLeave = (event: DragEvent) => {
    if (!this.inHost(event)) this.indicator.remove();
  };
  private drop = (event: DragEvent) => {
    if (!this.inHost(event) || !this.draggedID) return;
    event.preventDefault(); event.stopImmediatePropagation();
    moveBlock(this.editor, this.draggedID, this.dropTarget(event).pos);
    this.dragEnd();
  };
  private dragEnd = () => {
    this.listenToDrag(false);
    this.draggedID = null; this.view.dragging = null; this.indicator.remove(); this.hide();
  };
}

const BlockHandle = Extension.create({
  name: "dahliaBlockHandle",
  addProseMirrorPlugins() { return [new Plugin({ view: (view) => new BlockHandleView(view, this.editor) })]; },
});

/** Tiptap creates a local placeholder when opening an absent document. It is not user content. */
export class DocumentEditorHydration {
  private firstLocalUpdate = true;
  private locallyEdited = false;
  private hostVector: Uint8Array;
  constructor(private readonly document: Y.Doc, private readonly onRecovery: (blocks: DocumentBlock[]) => void = () => {}) {
    this.hostVector = Y.encodeStateVector(document);
  }
  edited() { this.locallyEdited = true; }
  captureLocalUpdate(update: Uint8Array): Uint8Array {
    if (!this.firstLocalUpdate) return update;
    this.firstLocalUpdate = false;
    // Editor initialization allocates clocks before observers attach. Include those
    // prerequisites even when remote hydration has since replaced the placeholder.
    return Y.encodeStateAsUpdate(this.document, this.hostVector);
  }
  receive(checkpoint: Uint8Array, vector = Y.encodeStateVectorFromUpdate(checkpoint)) {
    if (this.firstLocalUpdate) this.hostVector = vector;
    if (this.locallyEdited) {
      // Own save acknowledgements contain no new structs or deletions. Avoid a full
      // clone/projection for them, but never use clocks alone to skip a remote purge.
      if (!Y.snapshotContainsUpdate(Y.snapshot(this.document), checkpoint)) {
        const preview = new Y.Doc();
        try {
          Y.applyUpdate(preview, Y.encodeStateAsUpdate(this.document));
          const before = projectDocument(preview, false);
          Y.applyUpdate(preview, checkpoint);
          const after = projectDocument(preview, false);
          // The host may not have saved a throttled/queued edit, or may already have
          // discarded its structs under a purged parent. Clocks alone do not prove preservation.
          const lost = removedBlocks(before, after);
          if (lost.length) this.onRecovery(lost);
        }
        finally { preview.destroy(); }
      }
      const known = Y.decodeStateVector(vector);
      this.locallyEdited = [...Y.decodeStateVector(Y.encodeStateVector(this.document))]
        .some(([client, clock]) => clock > (known.get(client) ?? 0));
    }
    Y.applyUpdate(this.document, checkpoint, "remote");
  }
}
