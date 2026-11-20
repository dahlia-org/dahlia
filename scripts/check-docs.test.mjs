import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const checker = fileURLToPath(new URL("./check-docs.mjs", import.meta.url));

function check(t, files) {
  const cwd = mkdtempSync(join(tmpdir(), "dahlia-check-docs-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const init = spawnSync("git", ["init", "--quiet", cwd], { encoding: "utf8" });
  assert.equal(init.status, 0, init.stderr);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(cwd, path)), { recursive: true });
    writeFileSync(join(cwd, path), content);
  }
  return spawnSync(process.execPath, [checker], { cwd, encoding: "utf8" });
}

test("accepts indexed documents, Japanese and duplicate headings, and fenced examples", (t) => {
  const result = check(t, {
    "docs/README.md": "[Spec](spec/example.md#契約-1)\n",
    "docs/spec/example.md": "# 契約\n# 契約\n[First](#契約)\n```md\n[Example](missing.md)\n旧仕様\n```\n",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Checked 2 Markdown files/);
});

test("rejects missing paths and heading anchors", (t) => {
  const result = check(t, {
    "README.md": "# Root\n[File](missing.md)\n[Heading](#missing)\n[Other heading](other.md#missing)\n",
    "other.md": "# Other\n",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /broken link missing\.md/);
  assert.match(result.stderr, /broken heading link #missing/);
  assert.match(result.stderr, /broken heading link other\.md#missing/);
});

test("rejects machine-local links", (t) => {
  const result = check(t, { "README.md": "[Local](/Users/example/work/spec.md)\n" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /machine-local link/);
});

test("requires a README index link for documents under docs", (t) => {
  const result = check(t, { "docs/orphan.md": "# Orphan\n" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /not linked from any README\.md index/);
});

test("rejects amendment history while allowing approval and measurement dates", (t) => {
  const result = check(t, {
    "docs/README.md": "[Spec](spec/example.md)\n",
    "docs/spec/example.md": "# Contract\n承認日: 2026-11-20\n計測日: 2026-11-20\n2026-11-20 追記: 旧仕様\n",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /example\.md:4: amendment history/);
  assert.doesNotMatch(result.stderr, /example\.md:[23]:/);
});
