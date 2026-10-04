import { describe, expect, it } from "vitest";
import vectors from "../../../test-fixtures/typeid.json";
import { loadConfig } from "../src/config";
import { encodeId } from "@dahlia-ai/ui/model/typeid";
import { memoryBankId, memoryDocumentId, memoryDocumentSource } from "../src/memory/ids";
import { HindsightClient } from "../src/memory/hindsight";
import { contentHash, noteDocument } from "../src/memory/sources";

describe("Memory TypeIDs", () => {
  it.each(vectors)("uses the existing TypeID vector $uuid for every memory scope and source", ({ uuid, suffix }) => {
    const client = new HindsightClient({ url: "http://localhost:8888", auth: "none" }, undefined);
    expect(client.bank(uuid)).toBe(`dahlia_ws_${suffix}`);
    expect(client.bank(uuid, true)).toBe(`dahlia_user_${suffix}`);
    expect(memoryBankId(uuid)).toBe(client.bank(uuid));
    expect(memoryBankId(uuid, true)).toBe(client.bank(uuid, true));
    expect(memoryDocumentId("meeting", uuid)).toBe(`mtg_${suffix}`);
    expect(memoryDocumentId("shared", uuid)).toBe(`smem_${suffix}`);
    expect(memoryDocumentSource(`mtg_${suffix}`)).toEqual({ kind: "meeting", id: uuid });
    expect(memoryDocumentSource(`smem_${suffix}`)).toEqual({ kind: "shared", id: uuid });
  });

  it("rejects non-document types, malformed IDs, raw UUIDs and legacy names", () => {
    const uuid = vectors[2]!.uuid;
    for (const id of [uuid, `meeting-${uuid}`, `shared-${uuid}`, memoryBankId(uuid), encodeId("user", uuid),
      encodeId("workspace", uuid), encodeId("attachment", uuid), encodeId("file", uuid), "mtg_", "smem_8" + "0".repeat(25),
      "mtg_" + "i".repeat(26), "smem_" + "0".repeat(27), encodeId("meeting", uuid).toUpperCase()]) {
      expect(memoryDocumentSource(id)).toBeNull();
    }
    expect(() => memoryBankId(encodeId("workspace", uuid))).toThrow("invalid_uuid");
    expect(() => memoryDocumentId("meeting", encodeId("sharedMemory", uuid))).toThrow("invalid_uuid");
  });

  it("keeps the note identity across updates and scopes without changing canonical text or metadata", async () => {
    const id = vectors[2]!.uuid, time = new Date("2026-01-01T00:00:00Z");
    const note = { id, scopeId: id, createdBy: id, content: "Synthetic note", protected: true, revision: 1, updatedAt: time };
    const shared = noteDocument(note), personal = noteDocument(note, true);
    expect(shared.id).toBe(personal.id);
    expect(noteDocument({ ...note, revision: 2, content: "Updated note" }).id).toBe(shared.id);
    expect(shared.source).toEqual({ kind: "shared", id, revision: "1", projectId: null });
    const original = "User-registered shared information (not independently verified):\nSynthetic note";
    expect(shared.content).toBe(original);
    expect(await contentHash(shared.content)).toBe(await contentHash(original));
    expect(personal.content).toBe("Private user memory (not independently verified):\nSynthetic note");
  });
});

describe("Retired Hindsight bank prefix", () => {
  const env = { DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: "test-only-better-auth-secret-value" };
  it("configures Hindsight without any prefix setting", () => {
    expect(loadConfig({ ...env, DAHLIA_HINDSIGHT_URL: "http://localhost:8888", DAHLIA_HINDSIGHT_AUTH: "none" }).hindsight)
      .toEqual({ url: "http://localhost:8888", auth: "none", apiKey: undefined });
  });
  it.each(["", " ", "old-prefix", "SECRET-PREFIX"])("rejects a defined retired setting without echoing its value (%j)", (prefix) => {
    for (const url of [undefined, "http://localhost:8888"]) {
      expect(() => loadConfig({ ...env, DAHLIA_HINDSIGHT_URL: url, DAHLIA_HINDSIGHT_AUTH: "none", DAHLIA_HINDSIGHT_BANK_PREFIX: prefix }))
        .toThrow("DAHLIA_HINDSIGHT_BANK_PREFIX is no longer supported; remove it and use a dedicated Hindsight endpoint and storage for each environment");
    }
  });
});
