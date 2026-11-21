// Hermes Agent's injection scan for skill content (`tools/threat_patterns.py`, evaluated into threat-patterns.json).
import { readFileSync } from "node:fs";

const threats: { patterns: [string, string, string][]; invisible: number[] } =
  JSON.parse(readFileSync(new URL("./hermes/threat-patterns.json", import.meta.url), "utf8"));
const patterns = threats.patterns.map(([source, id]) => [new RegExp(source, "i"), id] as const);
const invisible = new Set(threats.invisible);
// The RGI subdivision flags (England, Scotland, Wales) are built from otherwise invisible tag characters.
const flags = ["gbeng", "gbsct", "gbwls"].map((code) =>
  String.fromCodePoint(0x1f3f4, ...[...code].map((c) => c.codePointAt(0)! + 0xe0000), 0xe007f));

/** Throws when the text carries invisible characters or matches a threat pattern. */
export function scanContent(content: string) {
  const raw = flags.reduce((text, flag) => text.replaceAll(flag, ""), content);
  for (const char of raw) {
    if (invisible.has(char.codePointAt(0)!)) throw new Error("Blocked: content contains invisible Unicode characters (possible injection).");
  }
  const text = content.normalize("NFKC").replace(/\s{2,}/g, (run) => (run.includes("\n") ? "\n" : " "));
  for (const [pattern, id] of patterns) {
    if (pattern.test(text)) throw new Error(`Blocked: content matches threat pattern '${id}'.`);
  }
}
