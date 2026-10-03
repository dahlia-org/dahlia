import * as Y from "yjs";
import { DocumentCore } from "../../src/documents/core";
import { blockMap, blockText, rootOrder, writeBlocks } from "../../src/documents/blocks";
export const firstBlock = (value: DocumentCore | Y.Doc) => {
  const doc = value instanceof DocumentCore ? value.document : value;
  return blockMap(doc).get(rootOrder(doc).get(0))!;
};
export const firstText = (value: DocumentCore | Y.Doc) => blockText(firstBlock(value));
export const deleteFirst = (value: DocumentCore | Y.Doc) => {
  const doc = value instanceof DocumentCore ? value.document : value;
  writeBlocks(doc, { blocks: [], removed: [rootOrder(doc).get(0)], order: new Map() }, null);
};

/** Synthetic near-limit state for the optional real workerd capacity check. */
export function capacityDocumentCheckpoint() {
  const core = new DocumentCore();
  try {
    const ids = Array.from({ length: 8000 }, () => crypto.randomUUID());
    writeBlocks(core.document, { blocks: ids.map((id, index) => ({ id, type: "paragraph" as const, parent: null, attrs: {},
      text: [{ insert: "日".repeat(index < 3000 ? 50 : 398) }] })), removed: [], order: new Map([[null, ids]]) }, null);
    writeBlocks(core.document, { blocks: [], removed: ids.slice(0, 3000), order: new Map() }, null);
    const checkpoint = core.checkpoint();
    return { checkpoint, textUnits: core.projection().text.length, totalBlocks: blockMap(core.document).size,
      stateBytes: checkpoint.length / 4 * 3 - (checkpoint.endsWith("==") ? 2 : checkpoint.endsWith("=") ? 1 : 0) };
  } finally { core.destroy(); }
}
