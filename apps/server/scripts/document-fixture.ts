// Regenerate only the portable, deterministic test data (no user documents).
import { writeFileSync } from "node:fs";
import { DocumentCore, removedBlocks } from "@dahlia-ai/ui/documents/core";
import { blockMap, blockText, writeBlocks } from "@dahlia-ai/ui/documents/blocks";
import v1 from "../../../packages/ui/tests/fixtures/documents-v1.json";

const core = new DocumentCore(); core.document.clientID = 101;
let sequence = 0;
core.insertText("会議\n# literal\r\n", () => `block-${++sequence}`);
const checkpoint = core.checkpoint(), vector = core.vector();
const a = new DocumentCore(checkpoint), b = new DocumentCore(checkpoint);
a.document.clientID = 102; b.document.clientID = 103;
blockText(blockMap(a.document).get("block-1")!).insert(1, "甲");
blockText(blockMap(b.document).get("block-1")!).insert(1, "乙");
const updates = [b.difference(vector), a.difference(vector), b.difference(vector)];
updates.forEach((update) => core.apply(update));
const projection = core.projection();
writeBlocks(core.document, { blocks: [], removed: ["block-1"], order: new Map() }, "fixture");
blockMap(core.document).get("block-1")!.set("deletedAt", 0);
const late = new DocumentCore(checkpoint), purged = new DocumentCore(core.checkpoint());
const retained = new DocumentCore(core.checkpoint()); retained.document.clientID = 105;
// A retained tombstone must not expire as persistence tests are rerun in later years.
blockMap(retained.document).get("block-1")!.set("deletedAt", Date.UTC(3000, 0, 1));
late.document.clientID = 104;
blockText(blockMap(late.document).get("block-1")!).insert(2, " offline");
purged.purgeDeletedBlocks(1);
const fixture = { checkpoint, updates, ...projection, deletionUpdate: core.checkpoint(), v1,
  lateUpdate: late.difference(vector), purgedCheckpoint: purged.checkpoint(),
  retainedDeletionUpdate: retained.checkpoint(),
  deleted: removedBlocks(projection, core.projection()) };
writeFileSync(new URL("../../macos/Tests/DahliaTests/Fixtures/documents.json", import.meta.url), `${JSON.stringify(fixture, null, 2)}\n`);
core.destroy(); a.destroy(); b.destroy(); late.destroy(); purged.destroy(); retained.destroy();
