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
