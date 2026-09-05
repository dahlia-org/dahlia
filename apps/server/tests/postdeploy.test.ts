import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

it("registers the initial Databricks model and reports CLI errors", () => {
  const result = spawnSync("python3", [fileURLToPath(new URL("../../../deploy/databricks/scripts/test_postdeploy.py", import.meta.url))], { encoding: "utf8" });
  expect(result.stderr).toContain("Ran 2 tests");
  expect(result.stderr).toContain("OK");
  expect(result.status, result.stderr).toBe(0);
});
