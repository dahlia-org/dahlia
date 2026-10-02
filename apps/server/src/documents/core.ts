import * as Y from "yjs";
import { blockLayout, blockMap, rootOrder, blockText, inlineText, purgeDeletedBlocks, textBlock, totalBlockLimit, validateBlocks, visibleBlockLimit, writeBlocks, type BlockInput, type Inline, type LayoutNode } from "./blocks";

export const documentSchemaVersion = 2;
export const documentTextLimit = 2_000_000;
export const documentStateLimit = 8 * 1024 * 1024;
// The first edit/import can contain a whole valid state, including prerequisite clocks.
export const documentUpdateLimit = documentStateLimit;

export interface DocumentBlock { id: string; type: string; text: string }
export interface DocumentProjection { text: string; blocks: DocumentBlock[] }
export interface DocumentRecovery { id: string; blocks: DocumentBlock[]; reason: "deleted" | "concurrent_delete" }
/** Snapshot ALL leaf bodies, including hidden ones; never serialize recovery bookkeeping. */
const projectedLeaves = new WeakMap<DocumentProjection, Map<string, DocumentBlock>>();

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
export function decodeBinary(value: string, limit = documentStateLimit): Uint8Array {
  if (value.length > Math.ceil(limit / 3) * 4 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("invalid_document_update");
  }
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  if (value.length / 4 * 3 - padding > limit) throw new Error("invalid_document_update");
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

/** Plain-text copy remains available even when an editor draft exceeds canonical limits. */
export function documentPlainText(document: Y.Doc): string {
  return projectDocument(document, false).text;
}

export function projectDocument(document: Y.Doc, limits = true): DocumentProjection {
  validateBlocks(document);
  const blocks: DocumentBlock[] = [], leaves = new Map<string, DocumentBlock>();
  for (const [id, block] of blockMap(document)) if (textBlock(block.get("type"))) leaves.set(id, { id, type: block.get("type") as string, text: inlineText(blockText(block).toDelta() as Inline[]) });
  const visit = (node: LayoutNode): string => {
    const text = textBlock(node.type) ? leaves.get(node.id)!.text : node.children.map(visit).join("\n");
    blocks.push({ id: node.id, type: node.type, text });
    return text;
  };
  const text = blockLayout(document).map(visit).join("\n");
  if (limits && (text.length > documentTextLimit || blocks.length > visibleBlockLimit || blockMap(document).size > totalBlockLimit)) throw new Error("document_too_large");
  const projection = { text, blocks }; projectedLeaves.set(projection, leaves); return projection;
}

/** Incremental bodies and layout. Full strings are assembled only for explicit reads. */
class DocumentIndex {
  readonly leaves = new Map<string, DocumentBlock>();
  private dirty = new Set<string>();
  private structural = true;
  private layout: LayoutNode[] = [];
  private visible = new Set<string>();
  private lengths = new Map<string, number>();
  private parents = new Map<string, string>();
  private textLength = 0;
  readonly diagnostics = { bodies: 0, layouts: 0 };
  constructor(private readonly document: Y.Doc) {
    blockMap(document).observeDeep((events) => {
      for (const event of events) {
        const id = event.path[0];
        if (typeof id === "string") this.dirty.add(id);
        else if (event instanceof Y.YMapEvent) for (const key of event.keysChanged) if (typeof key === "string") this.dirty.add(key);
        if (!(event instanceof Y.YTextEvent)) this.structural = true;
      }
    });
    rootOrder(document).observe(() => { this.structural = true; });
  }
  refresh(): DocumentBlock[] {
    const dirty = this.dirty, structural = this.structural, blocks = blockMap(this.document);
    // Also validate shared roots and unresolved dependencies when an update has no visible event.
    validateBlocks(this.document, structural ? new Set(blocks.keys()) : dirty, structural, dirty);
    const previous = new Map<string, DocumentBlock | undefined>();
    for (const id of dirty) {
      previous.set(id, this.leaves.get(id));
      const block = blocks.get(id);
      if (block && textBlock(block.get("type"))) {
        this.diagnostics.bodies++;
        this.leaves.set(id, { id, type: block.get("type") as string, text: inlineText(blockText(block).toDelta() as Inline[]) });
      } else this.leaves.delete(id);
    }
    const oldVisible = this.visible;
    if (structural) {
      this.diagnostics.layouts++;
      this.layout = blockLayout(this.document); this.visible = new Set(); this.parents.clear(); this.lengths.clear();
      const visit = (node: LayoutNode, parent?: string): number => {
        this.visible.add(node.id); if (parent) this.parents.set(node.id, parent);
        const length = textBlock(node.type) ? this.leaves.get(node.id)!.text.length
          : node.children.reduce((sum, child, i) => sum + visit(child, node.id) + (i ? 1 : 0), 0);
        this.lengths.set(node.id, length); return length;
      };
      this.textLength = this.layout.reduce((sum, node, i) => sum + visit(node) + (i ? 1 : 0), 0);
    } else {
      for (const id of dirty) if (this.visible.has(id)) {
        const length = this.leaves.get(id)!.text.length, delta = length - this.lengths.get(id)!;
        this.lengths.set(id, length); this.textLength += delta;
        for (let parent = this.parents.get(id); parent; parent = this.parents.get(parent)) this.lengths.set(parent, this.lengths.get(parent)! + delta);
      }
    }
    const recovered: DocumentBlock[] = [];
    for (const id of new Set([...dirty, ...(structural ? [...oldVisible].filter((id) => !this.visible.has(id)) : [])])) {
      if (this.visible.has(id)) continue;
      const old = previous.has(id) ? previous.get(id) : this.leaves.get(id), next = this.leaves.get(id) ?? old;
      if (next && (oldVisible.has(id) || (next.text.length > 0 && old?.text !== next.text))) recovered.push(next);
    }
    this.dirty = new Set(); this.structural = false; return recovered;
  }
  constraints() { return { text: this.textLength, visible: this.visible.size, total: blockMap(this.document).size }; }
  validateLimits(): void {
    if (this.textLength > documentTextLimit || this.visible.size > visibleBlockLimit || blockMap(this.document).size > totalBlockLimit) throw new Error("document_too_large");
  }
  projection(limits: boolean): DocumentProjection {
    this.refresh(); if (limits) this.validateLimits();
    const blocks: DocumentBlock[] = [];
    const visit = (node: LayoutNode): string => {
      const text = textBlock(node.type) ? this.leaves.get(node.id)!.text : node.children.map(visit).join("\n");
      blocks.push({ id: node.id, type: node.type, text }); return text;
    };
    const projection = { text: this.layout.map(visit).join("\n"), blocks };
    projectedLeaves.set(projection, new Map(this.leaves)); return projection;
  }
}

/** Owns a canonical Yjs document. Storage and scheduling belong to the host. */
export class DocumentCore {
  readonly document = new Y.Doc();
  private readonly index = new DocumentIndex(this.document);
  private sizeBudget = 2;
  changeVersion = 0;
  get diagnostics() { return this.index.diagnostics; }
  constructor(checkpoint?: string) {
    this.document.on("update", (update: Uint8Array) => { this.sizeBudget += update.byteLength + 64; this.changeVersion++; });
    if (checkpoint) this.apply(checkpoint);
    this.index.refresh(); this.sizeBudget = this.stateBytes();
  }
  destroy(): void { this.document.destroy(); }
  apply(update: string): DocumentBlock[] {
    this.index.refresh();
    const bytes = decodeBinary(update, Infinity);
    Y.applyUpdate(this.document, bytes, "persisted");
    return this.index.refresh();
  }
  constraints() { this.index.refresh(); return this.index.constraints(); }
  validate(previous?: ReturnType<DocumentCore["constraints"]>): void {
    this.index.refresh();
    try { this.index.validateLimits(); }
    catch (error) {
      const next = this.index.constraints();
      if (!previous || next.text > previous.text || next.visible > previous.visible || next.total > previous.total
        || (next.text === previous.text && next.visible === previous.visible && next.total === previous.total)) throw error;
      this.sizeBudget = this.stateBytes();
    }
    if (this.sizeBudget >= documentStateLimit * 0.9) this.sizeBudget = this.stateBytes();
    if (this.sizeBudget > documentStateLimit) throw new Error("document_too_large");
  }
  checkpoint(limits = true): string {
    const bytes = Y.encodeStateAsUpdate(this.document);
    this.sizeBudget = bytes.byteLength;
    if (limits && bytes.byteLength > documentStateLimit) throw new Error("document_too_large");
    return encodeBinary(bytes);
  }
  stateBytes(): number { return Y.encodeStateAsUpdate(this.document).byteLength; }
  vector(): string { return encodeBinary(Y.encodeStateVector(this.document)); }
  difference(vector?: string): string {
    return encodeBinary(Y.encodeStateAsUpdate(this.document, vector ? decodeBinary(vector) : undefined));
  }
  projection(limits = true): DocumentProjection { return this.index.projection(limits); }
  purgeDeletedBlocks(expiredBefore: number): number { return purgeDeletedBlocks(this.document, expiredBefore); }
  /** Literal import: no Markdown parsing, trimming, or line-ending normalization. */
  insertText(text: string, newID: () => string): string {
    const current = this.projection(false);
    if (text.length + current.text.length + (current.blocks.length ? 1 : 0) > documentTextLimit) throw new Error("document_too_large");
    const slots = Math.min(visibleBlockLimit - current.blocks.length, totalBlockLimit - blockMap(this.document).size);
    if (slots < 1) throw new Error("document_too_large");
    const before = this.vector();
    const lines = text.split("\n"), size = Math.ceil(lines.length / slots), inputs: BlockInput[] = [];
    for (let i = 0; i < lines.length; i += size) {
      const parts: Inline[] = [];
      lines.slice(i, i + size).forEach((line, j) => { if (j) parts.push({ insert: { type: "hardBreak" } }); if (line) parts.push({ insert: line }); });
      const id = newID();
      if (blockMap(this.document).has(id) || inputs.some((block) => block.id === id)) throw new Error("invalid_document_schema");
      inputs.push({ id, type: "paragraph", parent: null, attrs: {}, text: parts });
    }
    const change = { blocks: inputs, removed: [], order: new Map([[null, [...blockLayout(this.document).map((block) => block.id), ...inputs.map((block) => block.id)]]]) };
    // Imports are infrequent and must be atomic even at the encoded-state ceiling.
    const preview = new DocumentCore(this.checkpoint(false));
    try { writeBlocks(preview.document, change, "import"); preview.projection(); preview.checkpoint(); }
    finally { preview.destroy(); }
    writeBlocks(this.document, change, "import");
    return this.difference(before);
  }
  restore(blocks: DocumentBlock[], newID: () => string): string {
    // Recovery is an insertion, never an application of an old whole-document checkpoint.
    return this.insertText(blocks.map((block) => block.text).join("\n"), newID);
  }
}

export function removedBlocks(before: DocumentProjection, after: DocumentProjection): DocumentBlock[] {
  const live = new Set(after.blocks.map((block) => block.id)), visible = new Set(before.blocks.map((block) => block.id));
  const old = projectedLeaves.get(before) ?? new Map(before.blocks.filter((block) => textBlock(block.type)).map((block) => [block.id, block]));
  const next = projectedLeaves.get(after) ?? new Map(after.blocks.filter((block) => textBlock(block.type)).map((block) => [block.id, block]));
  const recovered: DocumentBlock[] = [];
  for (const id of new Set([...old.keys(), ...next.keys()])) {
    if (live.has(id)) continue;
    const previous = old.get(id), block = next.get(id) ?? previous;
    if (block && (visible.has(id) || (block.text.length > 0 && previous?.text !== block.text))) recovered.push(block);
  }
  return recovered;
}
export function mergeDocumentUpdates(updates: string[]): string {
  return encodeBinary(Y.mergeUpdates(updates.map((update) => decodeBinary(update))));
}

export function emptyDocumentUpdate(update: string): boolean {
  const decoded = Y.decodeUpdate(decodeBinary(update));
  return decoded.structs.length === 0 && decoded.ds.clients.size === 0;
}
