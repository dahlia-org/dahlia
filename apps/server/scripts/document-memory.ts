// Synthetic maximum-size synchronization. Run: node --expose-gc --import tsx scripts/document-memory.ts
import { DocumentCore, removedBlocks } from "../src/documents/core";
import { writeBlocks, type BlockInput } from "../src/documents/blocks";

globalThis.gc?.();
const baseline = process.memoryUsage().heapUsed;
const samples: { phase: string; heapMiB: number; retainedMiB?: number }[] = [];
const sample = (phase: string) => {
  const heapMiB = Math.round((process.memoryUsage().heapUsed - baseline) / 1024 / 1024 * 10) / 10;
  if (process.argv.includes("--collect")) globalThis.gc?.();
  samples.push({ phase, heapMiB, ...(process.argv.includes("--collect") ? { retainedMiB: Math.round((process.memoryUsage().heapUsed - baseline) / 1024 / 1024 * 10) / 10 } : {}) });
};
const source = new DocumentCore();
const blocks: BlockInput[] = Array.from({ length: 8_000 }, (_, i) => ({ id: `block-${i}`, type: "paragraph", parent: null, attrs: {}, text: [{ insert: "日".repeat(i < 3_000 ? 16 : 398) }] }));
writeBlocks(source.document, { blocks, removed: blocks.slice(0, 3_000).map((block) => block.id), order: new Map([[null, blocks.map((block) => block.id)]]) }, null);
sample("source");
const checkpoint = source.checkpoint(), server = new DocumentCore(checkpoint);
sample("decode");
const before = server.projection();
server.apply(checkpoint); const after = server.projection(); removedBlocks(before, after);
sample("merge-and-recovery");
server.purgeDeletedBlocks(0); const result = server.checkpoint(); server.projection();
sample("purge-and-encode");
console.log(JSON.stringify({ node: process.version, visible: before.blocks.length, total: blocks.length, utf16: before.text.length,
  checkpointBytes: Buffer.from(checkpoint, "base64").length, resultBytes: Buffer.from(result, "base64").length, samples }));
source.destroy(); server.destroy();
