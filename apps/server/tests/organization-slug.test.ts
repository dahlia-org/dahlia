import { expect, it } from "vitest";
import { organizationSlugFromName } from "../src/auth/organization-slug";

it("generates an editable organization slug from its name", () => {
  expect(organizationSlugFromName("  ACME ＆ Research  ")).toBe("acme-research");
  expect(organizationSlugFromName("株式会社ダリア")).toBe("organization");
});
