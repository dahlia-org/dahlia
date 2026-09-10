import { Hono } from "hono";
import { installPublicIDs } from "../src/public-http";
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import vectors from "../../../test-fixtures/typeid.json";
import { decodeId, encodeId, idPrefixes, type IDKind } from "../src/typeid";
import { wireDocument, wireValue, wireURL } from "../src/public-wire";

const uuid = vectors[2]!.uuid;
describe("public TypeIDs", () => {
  it("converts nested MCP organization and recording IDs without touching opaque metadata", () => {
    const value = { organization: { id: uuid, parent_organization_id: null }, nodes: [{ id: uuid }],
      memberships: [{ organization_id: uuid }], references: [{ resource_type: "organization", resource_id: uuid }],
      transcript: { metadata: { runs: [{ recording_session_id: uuid, response: { id: uuid } }] } } };
    const encoded = wireValue(value, "mcpResult", "encode") as typeof value;
    expect(encoded.organization.id).toBe(encodeId("organization", uuid));
    expect(encoded.nodes[0]!.id).toBe(encodeId("organization", uuid));
    expect(encoded.memberships[0]!.organization_id).toBe(encodeId("organization", uuid));
    expect(encoded.references[0]!.resource_id).toBe(encodeId("organization", uuid));
    expect(encoded.transcript.metadata.runs[0]!.recording_session_id).toBe(encodeId("recording", uuid));
    expect(encoded.transcript.metadata.runs[0]!.response.id).toBe(uuid);
    expect(wireValue(encoded, "mcpResult", "decode")).toEqual(value);
  });
  it("matches shared UUID vectors for every prefix", () => {
    for (const kind of Object.keys(idPrefixes) as IDKind[]) for (const vector of vectors) {
      const expected = `${idPrefixes[kind]}_${vector.suffix}`;
      expect(encodeId(kind, vector.uuid)).toBe(expected);
      expect(decodeId(kind, expected)).toBe(vector.uuid);
    }
  });
  it("rejects raw UUIDs, wrong types, invalid characters, lengths and overflow", () => {
    for (const value of [uuid, encodeId("meeting", uuid), "vlt_8" + "0".repeat(25), "vlt_" + "a".repeat(25), "vlt_" + "0".repeat(25) + "I", "VLT_" + "0".repeat(26)]) {
      expect(() => decodeId("vault", value)).toThrow();
    }
  });
  it("preserves document whitespace and non-reference UUID text", () => {
    const document = `{ "sections": [{"id":"${uuid}","blocks":[{"id":"${uuid}","screenshot_id":"${uuid}","content":{"text":"${uuid}"}}]}] }`;
    const publicDocument = wireDocument(document, "encode");
    expect(publicDocument).toContain(`"screenshot_id":"${encodeId("attachment", uuid)}"`);
    expect(publicDocument).toContain(`"text":"${uuid}"`);
    expect(wireDocument(publicDocument, "decode")).toBe(document);
  });
  it("uses the referenced type rather than the operation entity name", () => {
    const value = { id: uuid, vaultId: uuid, operations: [{ id: uuid, entity: "summary", entityId: uuid, data: { document: "plain text" } }] };
    const publicValue = wireValue(value, "transaction", "encode") as typeof value;
    expect(publicValue.operations[0]!.entityId).toBe(encodeId("meeting", uuid));
    expect(wireValue(publicValue, "transaction", "decode")).toEqual(value);
  });
  it("converts resource URLs and preserves opaque versions", () => {
    const url = `/api/v1/vaults/${uuid}/meetings/${uuid}/summary/3`;
    expect(wireURL(wireURL(url, "encode"), "decode")).toBe(url);
    expect(() => wireURL(url, "decode")).toThrow();
  });
  it("converts invitation team arrays and stored comma-separated team IDs", () => {
    const team = encodeId("team", uuid);
    expect(wireValue({ teamId: [team, team] }, "authInviteRequest", "decode")).toEqual({ teamId: [uuid, uuid] });
    expect(wireValue({ teamId: `${uuid},${uuid}` }, "invitation", "encode")).toEqual({ teamId: `${team},${team}` });
    expect(() => wireValue({ teamId: [team, uuid] }, "authInviteRequest", "decode")).toThrow();
  });
  it.each([null, "provider_failed"])("converts job identifiers when its error field is %s", (error) => {
    const value = { job: { id: uuid, error, input: { recordings: [{ micFileId: uuid, systemFileId: null }] },
      transcriptResult: { transcriptId: uuid } } };
    const encoded = wireValue(value, "summaryJobResponse", "encode") as typeof value;
    expect(encoded.job.id).toBe(encodeId("summaryJob", uuid));
    expect(encoded.job.input.recordings[0]!.micFileId).toBe(encodeId("file", uuid));
    expect(encoded.job.transcriptResult.transcriptId).toBe(encodeId("transcript", uuid));
    expect(wireValue(encoded, "summaryJobResponse", "decode")).toEqual(value);
    expect(wireURL(`/api/v1/vaults/${encodeId("vault", uuid)}/meetings/${encodeId("meeting", uuid)}/summary/job/${encoded.job.id}/cancel`, "decode", "POST"))
      .toContain(`/summary/job/${uuid}/cancel`);
  });
  it("preserves empty auth failures and immutable redirect responses", async () => {
    const app = new Hono();
    app.get("/api/auth/admin/list-users", () => new Response("", { status: 401, headers: { "content-type": "application/json" } }));
    app.get("/api/auth/verify-email", () => Response.redirect("https://dahlia.example/dashboard"));
    installPublicIDs(app);
    const failure = await app.request("/api/auth/admin/list-users");
    expect(failure.status).toBe(401);
    expect(await failure.text()).toBe("");
    const redirect = await app.request("/api/auth/verify-email");
    expect(redirect.status).toBe(302);
    expect(redirect.headers.get("location")).toBe("https://dahlia.example/dashboard");
  });
  it("shares the explicit field contract with Swift", () => {
    expect(readFileSync(new URL("../src/public-id-contract.json", import.meta.url), "utf8"))
      .toBe(readFileSync(new URL("../../desktop/Sources/DahliaRuntimeSupport/Resources/PublicIDContract.json", import.meta.url), "utf8"));
  });
});
