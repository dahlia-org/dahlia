# pi-auto-review

Source: https://github.com/mats16/pi-auto-review
Commit: b7822c1a1cdc52513a0d1f5bd342288a005fbdd2
License: MIT (see LICENSE)

These files are unchanged upstream sources. Dahlia imports `review` from `index.ts` for registered MCP mutation calls only;
it does not load the default extension or its commands. Update these three files together from a reviewed upstream commit
and run `apps/macos/scripts/test-pi-extension.py`. Pi supplies the peer dependencies; no runtime install is needed.
