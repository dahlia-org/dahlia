# Choosing a Project structure

Read this when deciding the target organization in step 4. It explains why the guidelines in `SKILL.md` hold, so you
can apply them to cases they do not name.

## What a Project is for

A Project groups Meetings that share durable context. Dahlia uses that grouping in three places:

- Summary generation receives the Project description, so Meetings in one Project should benefit from the same
  participants, product names, and glossary.
- Users and agents filter by `project_id` to follow a stream of work over time.
- A workspace with an export folder writes Summaries under the Project's derived path.

Group Meetings when one description would help all of their summaries. Split them when a shared description would
need to cover unrelated counterparts or contradictory terms.

## Shape

- Root: the durable counterpart or activity. One per customer company (`customer`), per internal team, function, or
  recurring Meeting family (`internal`), or per personal activity (`personal`). Use `undefined` only when the evidence
  does not settle the kind.
- Subproject: a durable slice of the root that has its own participants or vocabulary, such as a department, an
  opportunity, an implementation, or a named initiative. The hierarchy has only these two levels.
- Meetings stay on the root when no subproject clearly fits. A root with direct Meetings and subprojects is normal.

## When to split or keep together

| Situation | Choice |
| --- | --- |
| Several Meetings with the same customer but different departments that use different systems | One customer root, one subproject per department |
| A sales opportunity and the later implementation with the same customer | One customer root, one subproject per engagement |
| A recurring one-on-one | One internal root for the family, one subproject per counterpart identified in the evidence |
| A single Meeting with weak evidence | Leave it unassigned or keep its current Project |
| Meetings split only by date, quarter, or Meeting format | Keep them in one Project; dates and formats are filters, not Projects |
| Two Projects that cover the same work | Report the overlap and propose moving Meetings; Projects cannot be merged or deleted through the tools |

Prefer fewer, longer-lived Projects. A Project that will only ever hold one Meeting adds a filter nobody uses and a
description nobody maintains.

## Naming

- Use the counterpart's official name for a customer root, in the form the user already uses elsewhere in the
  Workspace. Keep one language per Workspace unless the user mixes them on purpose.
- Name subprojects after the durable work (`Data platform migration`), not after a date, a Meeting title, or a status
  (`Q3 kickoff`, `Ongoing`).
- Never put a path, a slash-separated hierarchy, or the parent's name in a Project name; the hierarchy is stored by
  parent ID.
- Avoid catch-all names such as `Misc` or `Other`. Leave unclear Meetings unassigned instead.
- Renaming a Project moves its tracked Summary exports; rename only when the new name is clearly better.

## Descriptions that pay off

A description is resent with every summary in the Project, so spend it on facts that fix recurring transcription and
summarization errors: official spellings of company, product, and people's names, role of each recurring participant,
and expansions of acronyms and internal jargon. Leave dated status and action items to the Meeting summaries.
