import { expect, it } from "vitest";
import { isReservedTeamOrganizationSlug, organizationSlugFromName } from "../src/auth/organization-slug";

it("generates an editable organization slug from its name", () => {
  expect(organizationSlugFromName("  ACME ＆ Research  ")).toBe("acme-research");
  expect(organizationSlugFromName("株式会社ダリア")).toBe("organization");
  expect(organizationSlugFromName("Personal Finance")).toBe("team-personal-finance");
  expect(isReservedTeamOrganizationSlug("personal-finance")).toBe(true);
});
