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
    extensions: [StarterKit.configure({ undoRedo: false, trailingNode: false, codeBlock: false, blockquote: false, horizontalRule: false, dropcursor: { width: 2 },
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

/** The block a handle moves: the innermost list item, otherwise the top-level block. */
function draggableBlock($pos: ResolvedPos): number | null {
  for (let depth = $pos.depth; depth > 0; depth--) if ($pos.node(depth).type.name === "listItem") return $pos.before(depth);
  if ($pos.depth > 0) return $pos.before(1);
  return $pos.nodeAfter ? $pos.pos : $pos.nodeBefore ? $pos.pos - $pos.nodeBefore.nodeSize : null;
}

/** Resolve the ID again at drop: remote edits may have changed the source position. */
class BlockHandleView {
  private readonly handle: HTMLElement;
  private pos: number | null = null;
  private draggedID: string | null = null;
  constructor(private readonly view: EditorView, private readonly editor: Editor) {
    this.handle = view.dom.ownerDocument.createElement("div");
    this.handle.className = "dahlia-block-handle";
    this.handle.draggable = true;
    this.handle.setAttribute("aria-hidden", "true");
    this.handle.innerHTML = '<svg viewBox="0 0 10 16" width="10" height="16" fill="currentColor">'
      + [3, 8, 13].map((y) => `<circle cx="2.5" cy="${y}" r="1.5"/><circle cx="7.5" cy="${y}" r="1.5"/>`).join("") + "</svg>";
    view.dom.addEventListener("mousemove", this.hover);
    view.dom.addEventListener("mouseleave", this.leave);
    this.handle.addEventListener("mouseleave", this.leave);
    this.handle.addEventListener("dragstart", this.dragStart);
    this.handle.addEventListener("dragend", this.dragEnd);
    view.dom.addEventListener("drop", this.drop, true);
  }
  update(view: EditorView, previous: { doc: Node }) {
    // A stale position could move the wrong block after typing or a remote change.
    if (view.state.doc !== previous.doc) this.hide();
  }
  destroy() {
    this.view.dom.removeEventListener("mousemove", this.hover);
    this.view.dom.removeEventListener("mouseleave", this.leave);
    this.view.dom.removeEventListener("drop", this.drop, true);
    this.handle.remove();
  }
  private hide() { this.pos = null; this.handle.style.display = "none"; }
  private hover = (event: MouseEvent) => {
    const { view } = this;
    if (!view.editable || view.dragging) return this.hide();
    const bounds = view.dom.getBoundingClientRect();
    const hit = view.posAtCoords({ left: Math.min(Math.max(event.clientX, bounds.left + 1), bounds.right - 1), top: event.clientY });
    const pos = hit ? draggableBlock(view.state.doc.resolve(hit.pos)) : null;
    const block = pos === null ? null : view.nodeDOM(pos);
    if (pos === null || !(block instanceof HTMLElement)) return this.hide();
    const box = block.getBoundingClientRect();
    if (event.clientY < box.top || event.clientY > box.bottom) return this.hide();
    const host = view.dom.parentElement!;
    if (this.handle.parentElement !== host) { host.style.position = "relative"; host.appendChild(this.handle); }
    this.pos = pos;
    this.handle.style.display = "flex";
    // Sit left of the bullet for list items, and center on the block's first line.
    const anchor = (block.tagName === "LI" ? block.parentElement! : block).getBoundingClientRect().left;
    const line = view.coordsAtPos(pos + (block.tagName === "LI" ? 2 : 1));
    const origin = host.getBoundingClientRect();
    this.handle.style.left = `${anchor - origin.left - this.handle.offsetWidth}px`;
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
  };
  private drop = (event: DragEvent) => {
    if (!this.draggedID) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const hit = this.view.posAtCoords({ left: event.clientX, top: event.clientY });
    if (hit) moveBlock(this.editor, this.draggedID, hit.pos);
    this.dragEnd();
  };
  private dragEnd = () => { this.draggedID = null; this.view.dragging = null; this.hide(); };
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
