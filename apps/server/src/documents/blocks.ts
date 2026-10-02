import * as Y from "yjs";

export const visibleBlockLimit = 5_000, totalBlockLimit = 8_000, documentDepthLimit = 64, documentURLLimit = 8_192;
export const blockTypes = ["paragraph", "heading", "bulletList", "orderedList", "listItem"] as const;
export type BlockType = typeof blockTypes[number];
export type BlockMap = Y.Map<unknown>;
export type Attributes = Record<string, unknown>;
export interface Inline { insert: string | { type: "hardBreak" }; attributes?: Attributes }
export interface BlockInput { id: string; type: BlockType; attrs: Attributes; parent: string | null; text?: Inline[] }
export interface BlockChange { blocks: BlockInput[]; removed: string[]; order: Map<string | null, string[]> }
export interface LayoutNode { id: string; type: BlockType; block: BlockMap; children: LayoutNode[] }
export const textBlock = (type: unknown): boolean => type === "paragraph" || type === "heading";
export const blockMap = (doc: Y.Doc): Y.Map<BlockMap> => doc.getMap<BlockMap>("blocks");
export const rootOrder = (doc: Y.Doc): Y.Array<string> => doc.getArray<string>("root");
export const blockText = (block: BlockMap): Y.Text => block.get("text") as Y.Text;
/** Type and attrs are independent CRDT registers; concurrent changes can leave harmless stale attrs. */
export function renderedAttributes(type: BlockType, block: BlockMap): Attributes {
  const attrs = block.get("attrs") as Attributes;
  if (type === "heading") return { level: attrs.level ?? 1 };
  if (type === "orderedList") return { start: attrs.start ?? 1, type: attrs.type ?? null };
  return {};
}
export const inlineText = (parts: Inline[]): string => parts.map((part) => typeof part.insert === "string" ? part.insert : "\n").join("");
const marks = ["bold", "italic", "strike", "code", "underline", "link"];
const object = (value: unknown): value is Attributes => !!value && typeof value === "object" && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype;
const validID = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 128;
const fail = (): never => { throw new Error("invalid_document_schema"); };

/** Reject malformed storage, not legitimate concurrent tree conflicts. */
export function validateBlocks(doc: Y.Doc, ids?: ReadonlySet<string>, structure = true, textIDs = ids): void {
  if (doc.share.has("content")) throw new Error("unsupported_document_schema");
  if (doc.store.pendingStructs || doc.store.pendingDs) throw new Error("invalid_document_update");
  for (const name of doc.share.keys()) if (name !== "blocks" && name !== "root") fail();
  const blocks = blockMap(doc), root = rootOrder(doc);
  const array = (value: unknown) => {
    if (!(value instanceof Y.Array) || value.toArray().some((id) => !validID(id))) fail();
  };
  if (structure) array(root);
  for (const id of ids ?? blocks.keys()) {
    const block = blocks.get(id);
    if (!block) continue;
    if (!validID(id) || !(block instanceof Y.Map)) fail();
    const type = block.get("type"), attrs = block.get("attrs"), parent = block.get("parent");
    if (!blockTypes.includes(type as BlockType) || !object(attrs) || typeof block.get("alive") !== "boolean"
      || !(parent === null || validID(parent))) fail();
    for (const key of block.keys()) if (!["type", "attrs", "parent", "alive", "deletedAt", "text", "children"].includes(key)) fail();
    const deleted = block.get("deletedAt");
    if (deleted !== undefined && (typeof deleted !== "number" || !Number.isFinite(deleted))) fail();
    const attributes = attrs as Attributes;
    if (Object.keys(attributes).some((key) => !["level", "start", "type"].includes(key))) fail();
    if (attributes.level !== undefined && (!Number.isInteger(attributes.level) || Number(attributes.level) < 1 || Number(attributes.level) > 6)) fail();
    if (attributes.start !== undefined && !Number.isInteger(attributes.start)) fail();
    if (![undefined, null, "1", "a", "A", "i", "I"].includes(attributes.type as string)) fail();
    if (textBlock(type)) {
      if (!(block.get("text") instanceof Y.Text) || block.has("children")) fail();
      for (const part of !textIDs || textIDs.has(id) ? blockText(block).toDelta() as Inline[] : []) {
        if (typeof part.insert !== "string" && (!object(part.insert) || part.insert.type !== "hardBreak" || Object.keys(part.insert).length !== 1)) fail();
        for (const [mark, value] of Object.entries(part.attributes ?? {})) {
          if (!marks.includes(mark) || !object(value)) fail();
          if (mark === "link") {
            if (typeof (value as Attributes).href !== "string" || !/^(https?:|mailto:)/i.test((value as Attributes).href as string)) fail();
            if (((value as Attributes).href as string).length > documentURLLimit) throw new Error("document_too_large");
            if (Object.entries(value as Attributes).some(([key, v]) => !["href", "target", "rel", "class"].includes(key) || !(v === null || typeof v === "string"))) fail();
          } else if (Object.keys(value as Attributes).length) fail();
        }
      }
    } else { array(block.get("children")); if (block.has("text")) fail(); }
    const parentBlock = parent === null ? undefined : blocks.get(parent as string);
    if (parentBlock && (textBlock(parentBlock.get("type")) || (parentBlock.get("type") !== "listItem" && type !== "listItem")
      || (parentBlock.get("type") === "listItem" && type === "listItem"))) fail();
  }
}

/** Parent is authoritative; arrays only supply order. Never repair concurrent array entries. */
export function blockLayout(doc: Y.Doc): LayoutNode[] {
  const blocks = blockMap(doc), parents = new Map<string, string | null>();
  for (const [id, block] of blocks) if (block.get("alive")) parents.set(id, block.get("parent") as string | null);
  const done = new Set<string>(), detached = new Set<string>();
  for (const id of parents.keys()) {
    const path: string[] = [], positions = new Map<string, number>();
    let at: string | null | undefined = id;
    while (at != null && parents.has(at) && !done.has(at) && !positions.has(at)) {
      positions.set(at, path.length); path.push(at); at = parents.get(at);
    }
    if (at != null && positions.has(at)) {
      const candidate = path.slice(positions.get(at)).filter((key) => ["bulletList", "orderedList"].includes(blocks.get(key)!.get("type") as string)).sort()[0];
      if (candidate) { parents.set(candidate, null); detached.add(candidate); }
    }
    for (const key of path) done.add(key);
  }
  const children = new Map<string | null, string[]>();
  for (const [id, parent] of parents) { const ids = children.get(parent) ?? []; ids.push(id); children.set(parent, ids); }
  const visit = (parent: string | null, depth: number): LayoutNode[] => {
    if (depth > documentDepthLimit) return [];
    const order = parent === null ? rootOrder(doc) : blocks.get(parent)?.get("children") as Y.Array<string> | undefined;
    const seen = new Set<string>(), ids: string[] = [];
    for (const id of order?.toArray() ?? []) if (parents.has(id) && parents.get(id) === parent && !seen.has(id) && !detached.has(id)) { seen.add(id); ids.push(id); }
    for (const id of (children.get(parent) ?? []).sort()) if (!seen.has(id)) ids.push(id);
    const nodes: LayoutNode[] = [];
    for (const id of ids) {
      const block = blocks.get(id)!, type = block.get("type") as BlockType;
      if (parent === null && type === "listItem") continue;
      const nested = textBlock(type) ? [] : visit(id, depth + 1);
      if (!textBlock(type) && !nested.length) continue;
      if (type === "listItem") { if (!textBlock(nested[0]?.type)) continue; nested[0] = { ...nested[0]!, type: "paragraph" }; }
      nodes.push({ id, type, block, children: nested });
    }
    return nodes;
  };
  return visit(null, 1);
}

const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const rawText = (parts: Inline[]) => parts.map((part) => typeof part.insert === "string" ? part.insert : "\ufffc").join("");
/** Minimal text replacement, retaining the Y.Text identity and unaffected character clocks. */
export function writeInline(text: Y.Text, desired: Inline[]): void {
  const current = text.toDelta() as Inline[], before = rawText(current), after = rawText(desired);
  let start = 0, end = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  while (end < before.length - start && end < after.length - start && before[before.length - 1 - end] === after[after.length - 1 - end]) end++;
  // Y.Text indexes UTF-16. A replacement must not split a surrogate pair.
  if (start && /[\uDC00-\uDFFF]/.test(before[start] ?? after[start] ?? "")) start--;
  if (end && /[\uDC00-\uDFFF]/.test(before[before.length - end] ?? after[after.length - end] ?? "")) end--;
  if (before.length - start - end) text.delete(start, before.length - start - end);
  let offset = 0;
  for (const part of desired) {
    const length = typeof part.insert === "string" ? part.insert.length : 1;
    const from = Math.max(start, offset), to = Math.min(after.length - end, offset + length);
    if (from < to) {
      if (typeof part.insert === "string") text.insert(from, part.insert.slice(from - offset, to - offset), part.attributes ?? {});
      else text.insertEmbed(from, part.insert, part.attributes ?? {});
    }
    offset += length;
  }
  // Compare runs after the insertion. Format-only changes do not delete characters.
  const actual = text.toDelta() as Inline[];
  let ai = 0, aoffset = 0; offset = 0;
  for (const part of desired) {
    const length = typeof part.insert === "string" ? part.insert.length : 1;
    let pos = offset;
    while (pos < offset + length) {
      const run = actual[ai]!, runLength = typeof run.insert === "string" ? run.insert.length : 1;
      const to = Math.min(offset + length, aoffset + runLength);
      if (!equal(run.attributes ?? {}, part.attributes ?? {})) {
        const attributes: Attributes = {};
        for (const key of new Set([...Object.keys(run.attributes ?? {}), ...Object.keys(part.attributes ?? {})])) attributes[key] = part.attributes?.[key] ?? null;
        text.format(pos, to - pos, attributes);
      }
      if (typeof run.insert !== typeof part.insert && to - pos === 1) {
        text.delete(pos, 1);
        if (typeof part.insert === "string") text.insert(pos, part.insert.slice(pos - offset, pos - offset + 1), part.attributes ?? {});
        else text.insertEmbed(pos, part.insert, part.attributes ?? {});
      }
      pos = to;
      if (to === aoffset + runLength) { ai++; aoffset = to; }
    }
    offset += length;
  }
}

function stableIDs(current: string[], desired: string[]): Set<string> {
  const indices = new Map(current.map((id, i) => [id, i])), tails: number[] = [], previous: number[] = [];
  desired.forEach((id, i) => {
    const value = indices.get(id); if (value === undefined) return;
    let lo = 0, hi = tails.length;
    while (lo < hi) { const mid = (lo + hi) >>> 1; if (indices.get(desired[tails[mid]!]!)! < value) lo = mid + 1; else hi = mid; }
    previous[i] = lo ? tails[lo - 1]! : -1; tails[lo] = i;
  });
  const keep = new Set<string>();
  for (let i = tails.at(-1) ?? -1; i >= 0; i = previous[i]!) keep.add(desired[i]!);
  return keep;
}
const removeIDs = (array: Y.Array<string>, ids: Set<string>) => {
  const values = array.toArray();
  for (let i = values.length - 1; i >= 0; i--) if (ids.has(values[i]!)) array.delete(i, 1);
};

export function writeBlocks(doc: Y.Doc, change: BlockChange, origin: unknown): void {
  const blocks = blockMap(doc);
  const order = (parent: string | null) => parent === null ? rootOrder(doc) : blocks.get(parent)?.get("children") as Y.Array<string> | undefined;
  doc.transact(() => {
    for (const input of change.blocks) {
      let block = blocks.get(input.id);
      if (!block) {
        block = new Y.Map(); blocks.set(input.id, block);
        block.set("alive", true); block.set("parent", input.parent);
        block.set(textBlock(input.type) ? "text" : "children", textBlock(input.type) ? new Y.Text() : new Y.Array<string>());
      }
      if (block.get("type") !== input.type) block.set("type", input.type);
      if (!equal(block.get("attrs"), input.attrs)) block.set("attrs", input.attrs);
      if (input.text) writeInline(blockText(block), input.text);
    }
    for (const id of change.removed) {
      const block = blocks.get(id);
      if (!block || !block.get("alive")) continue;
      block.set("alive", false); block.set("deletedAt", Date.now());
      const parent = block.get("parent") as string | null;
      if (parent === null || !change.removed.includes(parent)) { const array = order(parent); if (array) removeIDs(array, new Set([id])); }
    }
    for (const [parent, proposed] of change.order) {
      const array = order(parent); if (!array) continue;
      const desired = proposed.filter((id) => blocks.get(id)?.get("alive") === true);
      const seen = new Set<string>();
      const current = array.toArray().filter((id) => {
        if (seen.has(id) || !blocks.get(id)?.get("alive") || blocks.get(id)?.get("parent") !== parent) return false;
        seen.add(id); return true;
      });
      const keep = stableIDs(current, desired);
      const moved = new Set(desired.filter((id) => !keep.has(id))), oldArrays = new Map<Y.Array<string>, Set<string>>();
      for (const id of moved) {
        const block = blocks.get(id); if (!block) return;
        const oldParent = block.get("parent") as string | null, oldArray = order(oldParent);
        if (oldArray && oldArray !== array) { const ids = oldArrays.get(oldArray) ?? new Set(); ids.add(id); oldArrays.set(oldArray, ids); }
        if (oldParent !== parent) block.set("parent", parent);
      }
      for (const [oldArray, ids] of oldArrays) removeIDs(oldArray, ids);
      removeIDs(array, moved);
      // Batch adjacent insertions. Repeated toArray/insert per ID creates quadratic garbage on paste.
      const values = array.toArray();
      let cursor = 0;
      for (let i = 0; i < desired.length;) {
        const id = desired[i]!;
        if (keep.has(id)) { cursor = values.indexOf(id, cursor) + 1; i++; continue; }
        const inserted: string[] = [];
        while (i < desired.length && !keep.has(desired[i]!)) inserted.push(desired[i++]!);
        array.insert(cursor, inserted); values.splice(cursor, 0, ...inserted); cursor += inserted.length;
      }
    }
  }, origin);
}

/** Canonical owner only; callers record recovery BEFORE physically removing bodies. */
export function purgeDeletedBlocks(doc: Y.Doc, expiredBefore: number): number {
  const blocks = blockMap(doc), descendants = new Map<string, string[]>(), purge = new Set<string>();
  for (const [id, block] of blocks) {
    const parent = block.get("parent") as string | null;
    if (parent !== null) { const ids = descendants.get(parent) ?? []; ids.push(id); descendants.set(parent, ids); }
  }
  const collect = (id: string) => {
    const pending = [id];
    while (pending.length) { const next = pending.pop()!; if (purge.has(next)) continue; purge.add(next); pending.push(...descendants.get(next) ?? []); }
  };
  const dead = [...blocks].filter(([, block]) => !block.get("alive")).sort(([a, x], [b, y]) => Number(x.get("deletedAt") ?? 0) - Number(y.get("deletedAt") ?? 0) || a.localeCompare(b));
  for (const [id, block] of blocks) if (block.get("parent") !== null && !blocks.has(block.get("parent") as string)) collect(id);
  for (const [id, block] of dead) if (Number(block.get("deletedAt") ?? 0) <= expiredBefore) collect(id);
  const remove = () => doc.transact(() => {
    for (const id of purge) blocks.delete(id);
    removeIDs(rootOrder(doc), purge);
    for (const block of blocks.values()) { const array = block.get("children"); if (array instanceof Y.Array) removeIDs(array as Y.Array<string>, purge); }
  }, "purge");
  remove();
  // Transaction cleanup must GC the deleted bodies before the next encoded-size measurement.
  if (blocks.size > 6_000 || Y.encodeStateAsUpdate(doc).byteLength > 6 * 1024 * 1024) {
    const alreadyPurged = purge.size;
    for (const [id] of dead) {
      if (blocks.size - (purge.size - alreadyPurged) <= 5_000) break;
      if (blocks.has(id)) collect(id);
    }
    remove();
    for (const [id] of dead) {
      if (!blocks.has(id)) continue;
      if (blocks.size <= 5_000 && Y.encodeStateAsUpdate(doc).byteLength <= 5 * 1024 * 1024) break;
      collect(id); remove();
    }
  }
  return purge.size;
}
