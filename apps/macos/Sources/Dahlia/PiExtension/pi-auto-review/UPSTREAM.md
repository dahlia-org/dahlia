# Upstream source

Source: https://github.com/mats16/pi-auto-review/tree/3a12a7db97760e0a22ae9b4c0fa52f1497b6b046 (MIT; see LICENSE).

`index.ts`, `LICENSE` and `package.json` are unchanged copies. Dahlia imports only `review()` and `configured` from
`index.ts` (`../mcp-review.ts`); Pi never loads the package's extension. Update all three files together from one commit.
