# Localized Release Notes

Create `.build/release-notes/release-note-ja.md` and `.build/release-notes/release-note-en.md`. Express the same supported facts in both languages; write natural text rather than a literal translation.

- Open with one or two sentences stating the main user value.
- Use only applicable headings: Japanese `## ハイライト`, `## 改善`, `## 修正`; English `## Highlights`, `## Improvements`, `## Fixes`.
- Keep three to eight outcome-focused bullets in total.
- Group related commits. Describe what users can do or what became more reliable.
- Mention material compatibility, migration, privacy, performance, reliability, or behavior changes.
- Omit internal module names, implementation types, raw commits, PR inventories, tests, CI, refactors, and dependency churn unless users directly experience the effect.
- End each file with its localized label and the same compare URL when the previous tag and repository URL are available.

Check both files against the inspected diff. Reject any claim that is unsupported or belongs only to an excluded module.
