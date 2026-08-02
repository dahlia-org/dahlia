---
name: projects-optimizer
description: Optimize Dahlia Projects, Project descriptions, and Meeting assignments through the vault-scoped Dahlia tools. Use when the user asks to classify or tidy Meetings, create or restructure Projects, rename or reparent Projects, assign or unassign Meetings, review unorganized recent Meetings, audit the Project hierarchy, or write, improve, or fill in the Project descriptions that Dahlia includes in summary generation.
---

# Projects Optimizer

Organize the active Dahlia Vault without treating directories as Projects or guessing from weak evidence.

## Workflow

### 1. Choose the Meeting period

- Honor explicit Meeting references, Project IDs, filters, and date boundaries from the user.
- For a broad request without dates, use the most recent 90 days and state the assumed period in the result.

### 2. Understand the Meetings

- Call `query_meetings` with the period as `created_from` / `created_before` and `limit: 100`; follow every cursor.
- For a nonblank `ical_uid`, call `query_meetings` with that UID and follow its cursors when series history can clarify
  the Meeting's purpose. Deduplicate the combined results by Meeting ID.
- Call `get_meeting` for Meetings that may need classification. Review the description, stored summary, and available
  calendar event metadata together, including the calendar title and `ical_uid`.
- Call `get_meeting_transcript` or `get_meeting_screenshots` only when the available metadata and summary do not provide
  enough evidence for the requested decision.

### 3. Inspect the existing Projects

- Call `query_projects` once to inspect the complete two-level hierarchy.
- Treat Project IDs and parent relationships as canonical. Never infer Projects from directories.

### 4. Decide the target organization

- Compare the existing hierarchy with all Meetings in scope before making changes.
- Reuse a clearly matching Project before creating one. Preserve an existing assignment when the evidence does not
  clearly support a better destination.
- Define the desired Project changes and Meeting-to-Project mapping together so Project structure is settled before
  assignments move.
- Separate uncertain Meetings from confident changes. Ask one focused question only when unresolved ambiguity
  materially changes the target organization.

### 5. Create or update Projects

Execute changes when the user asked to organize the Vault; do not stop after proposing a plan unless the user requested
analysis only.

- Call `create_project` with one name component, an optional root `parent_project_id`, a root `project_type` when
  appropriate, and a `description` when step 7's evidence is already in hand. Never submit a Project path.
- Before `update_project`, call `get_project` and pass its current `revision`. Omit unchanged properties. Use
  `parent_project_id: null` only to move a Project to the Vault root.
- Apply every property change for one Project in a single `update_project` call. A successful `create_project` or
  `update_project` returns the stored `project`; use its `revision` as the next expected revision instead of re-reading,
  and treat `changed: false` as a no-op rather than a change.
- Finish the supported structural Project changes before moving Meeting assignments. Descriptions come last, in step 7,
  because the assigned Meetings are their evidence.

### 6. Move Meeting assignments

- Use the latest read of each Meeting's current assignment as `expected_project_id`, including explicit `null`.
- Call `set_meeting_project_assignment` for one Meeting at a time. Call `remove_meeting_project_assignment` only when the
  user wants the Meeting unassigned.
- After a stale-state failure, re-fetch only that Project or Meeting and retry once if the requested intent remains
  valid. Continue independent changes when one item fails.

### 7. Write or refine Project descriptions

Dahlia includes a Project's `description` in the prompt for every summary generated in that Project, as
`<project><description>` inside a context block that summary generation treats as untrusted source data and never as
instructions. Write durable reference facts for that reader; a directive such as "always list risks first" is ignored by
design.

- Include the durable identity of the work: what the engagement or activity is, the counterpart organization and the
  recurring participants with their roles, the goal and scope, product, system, and team names, and expansions for
  acronyms and internal jargon. The expansions matter most, because they let summary generation resolve terms the
  transcript garbled.
- Exclude per-Meeting detail, action items, dated status, anything that goes stale, and anything the accessible evidence
  does not support. Do not invent facts.
- Base the text on the current description first, then the Meetings assigned to the Project. Read stored summaries and
  calendar metadata before transcripts, as in step 2.
- The user edits this field directly in Dahlia. Extend or tighten an existing description and keep its language and its
  user-supplied specifics. Report any substantial rewrite of user-written text.
- Match the language of the existing description, or of the Project's Meetings when it is blank.
- Keep it short: a paragraph or a few labeled lines. Dahlia resends the text with every summary, so never paste summary
  content into it.
- Call `get_project` for the current `revision`, then `update_project` with `description` alone. Skip the call when the
  text would not change.

## Organization guidelines

- Keep the hierarchy to a root and one subproject level. Use a root type matching the durable activity: `customer`,
  `internal`, `personal`, or `undefined`; let subprojects inherit it.
- Organize customer work with one `customer` root per company. Use subprojects for a department or a durable engagement
  such as an opportunity, implementation, or named initiative.
- Prefer an engagement subproject when a Meeting clearly belongs to specific work. Otherwise, use a department
  subproject when that relationship is clear.
- Infer internal Meeting groups dynamically from calendar titles, descriptions, summaries, and recurrence history.
  `QBR`, one-on-ones, planning, reviews, and team syncs are examples, not a fixed taxonomy.
- Use one `internal` root for a stable recurring Meeting family when supported by the evidence. For person-centered
  recurring Meetings, use one subproject per counterpart only when the accessible evidence explicitly identifies that
  person. Otherwise, keep the Meeting unchanged or ask who the counterpart is. For other families, use a team, subject,
  or series-specific subproject only when it makes the root more useful.
- Treat a shared `ical_uid` as strong evidence of the same calendar-event series and usually a consistent assignment.
  Confirm its purpose from metadata or summaries because a series can change purpose.
- Do not treat different or missing `ical_uid` values as proof of different Projects. Separate calendar events can still
  support the same customer, engagement, department, or internal Meeting family.
- Create a Project only for a coherent, durable stream of work. Do not create one for a single ambiguous Meeting.
- Never claim to delete or merge Projects: Dahlia does not expose those operations. Explain the limitation and complete
  independently requested supported changes.

## Report the result

Summarize the inspected scope, Projects created or updated, Project descriptions written or refined, Meetings moved or
unassigned, unchanged ambiguous items, and any failed or unsupported operations. Call out any user-written description
that a rewrite substantially replaced. Use Project names for readability and include IDs only when they help resolve
ambiguity or retry a failure.
