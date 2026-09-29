import { Editor, type EditorOptions } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Collaboration from "@tiptap/extension-collaboration";
import UniqueID from "@tiptap/extension-unique-id";
import { isChangeOrigin } from "@tiptap/extension-collaboration";
import * as Y from "yjs";
import { documentFragment } from "./core";

export function documentEditorOptions(document: Y.Doc, editable: boolean): Partial<EditorOptions> {
  return {
    editable,
    extensions: [StarterKit.configure({ undoRedo: false, codeBlock: false, blockquote: false, horizontalRule: false, hardBreak: false,
      link: { openOnClick: false, protocols: ["http", "https", "mailto"], isAllowedUri: (url) => /^(https?:|mailto:)/i.test(url) } }),
    Collaboration.configure({ document, field: documentFragment }),
    UniqueID.configure({ types: ["paragraph", "heading", "bulletList", "orderedList", "listItem"],
      updateDocument: editable, filterTransaction: (transaction) => !isChangeOrigin(transaction) })],
    editorProps: { attributes: { class: "dahlia-document", role: "textbox", "aria-multiline": "true" } },
  };
}
export function mountDocumentEditor(element: HTMLElement, document: Y.Doc, editable: boolean): Editor {
  return new Editor({ ...documentEditorOptions(document, editable), element });
}

/** Tiptap creates a local placeholder when opening an absent document. It is not user content. */
export class DocumentEditorHydration {
  private pristine: boolean;
  private firstLocalUpdate = true;
  private hostVector: Uint8Array;
  constructor(private readonly document: Y.Doc) {
    this.pristine = document.getXmlFragment(documentFragment).length === 0;
    this.hostVector = Y.encodeStateVector(document);
  }
  edited() { this.pristine = false; }
  captureLocalUpdate(update: Uint8Array): Uint8Array {
    if (!this.firstLocalUpdate) return update;
    this.firstLocalUpdate = false;
    // Editor initialization allocates clocks before observers attach. Include those
    // prerequisites even when remote hydration has since replaced the placeholder.
    return Y.encodeStateAsUpdate(this.document, this.hostVector);
  }
  receive(checkpoint: Uint8Array) {
    if (this.firstLocalUpdate) this.hostVector = Y.encodeStateVectorFromUpdate(checkpoint);
    if (this.pristine) {
      const incoming = new Y.Doc();
      try {
        Y.applyUpdate(incoming, checkpoint);
        if (incoming.getXmlFragment(documentFragment).length > 0) {
          this.pristine = false;
          const fragment = this.document.getXmlFragment(documentFragment);
          this.document.transact(() => { if (fragment.length) fragment.delete(0, fragment.length); }, "remote");
        }
      } finally { incoming.destroy(); }
    }
    Y.applyUpdate(this.document, checkpoint, "remote");
  }
}
