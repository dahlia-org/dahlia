import { describe, expect, it } from "vitest";
import { objectPath, parseObjectPath, legacyObjectPath } from "../src/model/object-url";
import { encodeId } from "../src/model/typeid";
import { resolveDashboardRoute, isCoreDashboardPath } from "../src/app/routes";
const capabilities = { admin: false, sessions: true, sync: true };
const uuid = "01990ab0-0000-7000-8000-000000000001";
describe("object URLs", () => {
  for (const kind of ["workspace", "project", "meeting", "file"] as const) {
    it(`resolves ${kind} and redirects its legacy URL`, () => {
      const id = encodeId(kind, uuid), path = objectPath(id);
      expect(path).toBe(`/o/${id}`);
      expect(parseObjectPath(path)).toEqual({ kind, id });
      expect(isCoreDashboardPath(path)).toBe(true);
      expect(resolveDashboardRoute(path, capabilities)).toEqual({ page: kind, [`${kind}Id`]: id });
      expect(legacyObjectPath(`/${kind}s/${id}`)).toBe(path);
      expect(resolveDashboardRoute(`/${kind}s/${id}`, capabilities)).toEqual({ redirect: path });
      expect(resolveDashboardRoute(path, { ...capabilities, sync: false })).toEqual({ redirect: "/dashboard" });
    });
  }
  it("rejects invalid IDs, unsupported kinds, mismatches and nested paths", () => {
    const meeting = encodeId("meeting", uuid);
    for (const path of ["/o/mtg_bad", "/o/mtg_zzzzzzzzzzzzzzzzzzzzzzzzzz", `/o/${encodeId("organization", uuid)}`, `/o/${encodeId("aiThread", uuid)}`, `/o/ws_bad/${meeting}`, `/projects/${meeting}`, `/workspaces/ws_bad/meetings/${meeting}`]) {
      expect(resolveDashboardRoute(path, capabilities)).toEqual({ redirect: "/dashboard" });
    }
  });
});
