#!/usr/bin/env node
// Checks repository Markdown: relative links resolve, no machine-local paths,
// every document under docs/ is reachable from an index, and current-state specs
// contain no amendment history (history belongs in commits and PRs).
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, normalize, relative } from "node:path";

const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const ignored = [/^\.agents\//, /^Vendor\//, /(^|\/)node_modules\//];
const files = execFileSync("git", ["ls-files", "-co", "--exclude-standard", "*.md"], { cwd: root, encoding: "utf8" })
  .split("\n")
  .filter((file) => file && !ignored.some((pattern) => pattern.test(file)) && existsSync(join(root, file)));

// Specs state only the current contract. Dates of user approvals and measurements are allowed.
const specDirectory = "docs/spec/";
// "追記" alone also means "append" (an append-only log), so only dated or labelled amendments count.
const historyMarkers = [/\d{4}-\d{2}-\d{2}\s*追記/, /追記[:：]/, /（追記）/, /旧仕様/, /旧決定/, /置換範囲/, /撤回/, /再改定/, /以前は/, /当初は/, /supersed/i];

const errors = [];
const anchorCache = new Map();

// GitHub heading slugs: lowercase, drop punctuation and symbols, spaces to hyphens, number duplicates.
function anchorsOf(file) {
  if (anchorCache.has(file)) return anchorCache.get(file);
  const anchors = new Set();
  const counts = new Map();
  let fenced = false;
  for (const line of readFileSync(join(root, file), "utf8").split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    const heading = !fenced && line.match(/^#{1,6}\s+(.*?)\s*#*\s*$/);
    if (!heading) continue;
    const text = heading[1].replace(/\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/<[^>]+>/g, "");
    const base = text.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "").replace(/ /g, "-");
    const count = counts.get(base) ?? 0;
    counts.set(base, count + 1);
    anchors.add(count === 0 ? base : `${base}-${count}`);
  }
  anchorCache.set(file, anchors);
  return anchors;
}
const linkTargets = new Map();
const linkPattern = /\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;

for (const file of files) {
  const lines = readFileSync(join(root, file), "utf8").split("\n");
  let fenced = false;
  lines.forEach((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    if (fenced) return;
    const where = `${file}:${index + 1}`;
    for (const [, rawTarget] of line.matchAll(linkPattern)) {
      if (/^(https?:|mailto:)/.test(rawTarget)) continue;
      if (rawTarget.startsWith("#")) {
        if (!anchorsOf(file).has(decodeURIComponent(rawTarget.slice(1)).toLowerCase())) errors.push(`${where}: broken heading link ${rawTarget}`);
        continue;
      }
      if (/^(\/Users\/|\/home\/|\/private\/|file:)/.test(rawTarget)) {
        errors.push(`${where}: machine-local link ${rawTarget}; link relative to the repository`);
        continue;
      }
      const [rawPath, rawAnchor] = rawTarget.split("#");
      const path = decodeURI(rawPath).replace(/:\d+$/, "");
      const target = normalize(path.startsWith("/") ? path.slice(1) : join(dirname(file), path));
      if (!existsSync(join(root, target))) {
        errors.push(`${where}: broken link ${rawTarget}`);
        continue;
      }
      if (rawAnchor && target.endsWith(".md") && !anchorsOf(target).has(decodeURIComponent(rawAnchor).toLowerCase())) {
        errors.push(`${where}: broken heading link ${rawTarget}`);
      }
      if (!linkTargets.has(target)) linkTargets.set(target, new Set());
      linkTargets.get(target).add(file);
    }
    if (file.startsWith(specDirectory)) {
      const marker = historyMarkers.find((pattern) => pattern.test(line));
      if (marker) errors.push(`${where}: amendment history (${marker.source}); rewrite the rule in the present tense and put the reason in the PR`);
    }
  });
}

// Every document under docs/ must be linked from an index (a README.md) so agents can find it.
for (const file of files.filter((file) => file.startsWith("docs/") && !file.endsWith("README.md"))) {
  const indexes = [...(linkTargets.get(file) ?? [])].filter((source) => source.endsWith("README.md"));
  if (indexes.length === 0) errors.push(`${file}: not linked from any README.md index; add it to the nearest index`);
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  console.error(`\n${errors.length} documentation problem(s) in ${relative(process.cwd(), root) || "."}`);
  process.exit(1);
}
console.log(`Checked ${files.length} Markdown files.`);
