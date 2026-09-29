import * as Y from "yjs";

export const documentSchemaVersion = 1;
export const documentFragment = "content";
export const documentTextLimit = 2_000_000;
export const documentStateLimit = 8 * 1024 * 1024;
// The first edit/import can contain a whole valid state, including prerequisite clocks.
export const documentUpdateLimit = documentStateLimit;
const blockTypes = new Set(["paragraph", "heading", "bulletList", "orderedList", "listItem", "blockquote", "codeBlock"]);

export interface DocumentBlock { id: string; type: string; text: string }
export interface DocumentProjection { text: string; blocks: DocumentBlock[] }
export interface DocumentRecovery { id: string; blocks: DocumentBlock[]; reason: "deleted" | "concurrent_delete" }

// Binary conversion deliberately avoids Buffer, atob and browser globals (JavaScriptCore).
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const alphabetValues = new Uint8Array(128);
for (let i = 0; i < alphabet.length; i++) alphabetValues[alphabet.charCodeAt(i)] = i;
export function encodeBinary(bytes: Uint8Array): string {
  const chunks: string[] = [], group: string[] = [];
  for (let i = 0; i < bytes.length; i += 3) {
    const value = (bytes[i]! << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    group.push(alphabet[value >>> 18]! + alphabet[(value >>> 12) & 63]!
      + (i + 1 < bytes.length ? alphabet[(value >>> 6) & 63]! : "=")
      + (i + 2 < bytes.length ? alphabet[value & 63]! : "="));
    if (group.length === 4096) { chunks.push(group.join("")); group.length = 0; }
  }
  chunks.push(group.join(""));
  return chunks.join("");
}
export function decodeBinary(value: string): Uint8Array {
  if (value.length > Math.ceil(documentStateLimit / 3) * 4 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("invalid_document_update");
  }
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  if (value.length / 4 * 3 - padding > documentStateLimit) throw new Error("invalid_document_update");
  const result = new Uint8Array(value.length / 4 * 3 - padding);
  for (let i = 0, j = 0; i < value.length; i += 4) {
    const bits = (alphabetValues[value.charCodeAt(i)]! << 18) | (alphabetValues[value.charCodeAt(i + 1)]! << 12)
      | (alphabetValues[value.charCodeAt(i + 2)]! << 6) | alphabetValues[value.charCodeAt(i + 3)]!;
    result[j++] = bits >>> 16;
    if (j < result.length) result[j++] = bits >>> 8;
    if (j < result.length) result[j++] = bits;
  }
  return result;
}

function elementText(element: Y.XmlElement): string {
  return element.toArray().map((node) => node instanceof Y.XmlText ? (node.toDelta() as { insert: unknown }[]).map((part: { insert: unknown }) => typeof part.insert === "string" ? part.insert : "").join("")
    : node instanceof Y.XmlElement ? elementText(node) : "").join(
    ["bulletList", "orderedList", "blockquote", "listItem"].includes(element.nodeName) ? "\n" : "",
  );
}

/** Plain-text copy remains available even when an editor draft exceeds canonical limits. */
export function documentPlainText(document: Y.Doc): string {
  return document.getXmlFragment(documentFragment).toArray().map((element) => elementText(element as Y.XmlElement)).join("\n");
}

/** Owns a canonical Yjs document. Storage and scheduling belong to the host. */
export class DocumentCore {
  readonly document = new Y.Doc();
  constructor(checkpoint?: string) {
    if (checkpoint) this.apply(checkpoint);
  }
  destroy(): void { this.document.destroy(); }
  apply(update: string): void { Y.applyUpdate(this.document, decodeBinary(update), "persisted"); }
  checkpoint(): string { return encodeBinary(Y.encodeStateAsUpdate(this.document)); }
  stateBytes(): number { return Y.encodeStateAsUpdate(this.document).byteLength; }
  vector(): string { return encodeBinary(Y.encodeStateVector(this.document)); }
  difference(vector?: string): string {
    return encodeBinary(Y.encodeStateAsUpdate(this.document, vector ? decodeBinary(vector) : undefined));
  }
  projection(): DocumentProjection {
    const blocks: DocumentBlock[] = [];
    const visit = (element: Y.XmlElement, depth: number) => {
      if (depth > 64 || !blockTypes.has(element.nodeName)) throw new Error("invalid_document_schema");
      const id = element.getAttribute("id");
      for (const child of element.toArray()) if (child instanceof Y.XmlElement) visit(child, depth + 1);
      if (id) blocks.push({ id, type: element.nodeName, text: elementText(element) });
    };
    const root = this.document.getXmlFragment(documentFragment);
    for (const child of root.toArray()) {
      if (!(child instanceof Y.XmlElement)) throw new Error("invalid_document_schema");
      visit(child, 0);
    }
    const text = documentPlainText(this.document);
    if (text.length > documentTextLimit || blocks.length > 50_000) throw new Error("document_too_large");
    return { text, blocks };
  }
  /** Only the canonical worker repairs IDs; the resulting update is distributed to every peer. */
  repairBlockIDs(newID: () => string): string {
    const before = this.vector();
    const seen = new Set<string>();
    this.document.transact(() => {
      const visit = (element: Y.XmlElement) => {
        let id = element.getAttribute("id");
        if (!id || seen.has(id)) { id = newID(); element.setAttribute("id", id); }
        seen.add(id);
        for (const child of element.toArray()) if (child instanceof Y.XmlElement) visit(child);
      };
      for (const child of this.document.getXmlFragment(documentFragment).toArray()) if (child instanceof Y.XmlElement) visit(child);
    }, "repair");
    return this.difference(before);
  }
  /** Literal import: no Markdown parsing, trimming, or line-ending normalization. */
  insertText(text: string, newID: () => string): string {
    if (text.length > documentTextLimit) throw new Error("document_too_large");
    const before = this.vector();
    this.document.transact(() => {
      const root = this.document.getXmlFragment(documentFragment);
      const paragraphs = text.split("\n").map((line) => {
        const paragraph = new Y.XmlElement("paragraph");
        paragraph.setAttribute("id", newID());
        if (line.length) { const text = new Y.XmlText(); text.insert(0, line); paragraph.insert(0, [text]); }
        return paragraph;
      });
      root.insert(root.length, paragraphs);
    }, "import");
    return this.difference(before);
  }
  restore(blocks: DocumentBlock[], newID: () => string): string {
    // Recovery is an insertion, never an application of an old whole-document checkpoint.
    return this.insertText(blocks.map((block) => block.text).join("\n"), newID);
  }
}

export function removedBlocks(before: DocumentProjection, after: DocumentProjection): DocumentBlock[] {
  const live = new Set(after.blocks.map((block) => block.id));
  // Leaf blocks avoid duplicating both list containers and their paragraphs in recovery.
  return before.blocks.filter((block) => !live.has(block.id) && ["paragraph", "heading", "codeBlock"].includes(block.type));
}
export function mergeDocumentUpdates(updates: string[]): string {
  return encodeBinary(Y.mergeUpdates(updates.map(decodeBinary)));
}

export function emptyDocumentUpdate(update: string): boolean {
  const decoded = Y.decodeUpdate(decodeBinary(update));
  return decoded.structs.length === 0 && decoded.ds.clients.size === 0;
}
