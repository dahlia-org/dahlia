<!--
Reviewers, including AI reviewers, read the diff and the repository but not your conversation, linked pages, images, or manual check results.
Write what they cannot get from the diff: intent, scope decisions, and verification facts. Do not summarize the diff or list files.
- Keep every heading and field label so reviewers can find them. Write "N/A" when one does not apply.
- One fact per bullet. Describe behavior, not code the diff already shows.
- Write only what you confirmed. Label anything you inferred but did not check as an assumption.
- Update this description when review changes the behavior or the verification results.
-->

## Why

<!-- The problem, why it needs solving, and the result users should see. -->

-

## What changes

<!-- Behavior and contract changes (schemas, migrations, settings and defaults, APIs, MCP tools, storage formats), written as before → after. -->

-

## Review guide

<!--
- Start here: the file and symbol where the main path begins, so the reviewer can trace it.
- Key decisions: each non-obvious choice, the constraint behind it and how you confirmed that constraint, and the alternative you rejected.
- Surfaces: for each surface in the AGENTS.md Definition of Done (clients, accounts, entry points, AI access, reverse paths), whether it changed or was deliberately left out, and why.
- Unchanged: behavior and contracts this PR guarantees it does not change.
- Focus: the risks or open questions you want the reviewer to check.
-->

- Start here:
- Key decisions:
- Surfaces:
- Unchanged:
- Focus:

## Verification

<!--
List only what you actually ran: the command or steps and a concrete result, such as suite names, test counts, or observed behavior. A test you added but did not run does not count.
For a bug fix, name the test or reproduction that failed before the fix and passes after it.
-->

### Done

-

### Not done

<!-- Each check you skipped or could not run, why, and the next step to verify it. "None" if everything ran. -->

-

## Impact and risk

<!--
Cover whichever apply: user-visible behavior, recording and transcription, the database, settings, MCP and backups, telemetry and external network calls, compatibility, and known limits.
Needs human approval: the conditions under "承認の扱い" in docs/code-review.md that this PR meets, or "None".
-->

- Needs human approval:
- Affected areas:
- Remaining risks and known limits:
- Recovery if it goes wrong:

## UI check

<!-- For UI changes, add before/after screenshots and also describe in text the states and interactions you checked by hand. "N/A" if there is no UI change. -->

-

## Related

<!-- For example: Closes #123, related PRs, design docs. Summarize anything from a linked page that the review depends on. "None" if nothing applies. -->

-
