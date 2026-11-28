# Search patterns

## What each parameter matches

| Parameter | Matches | Notes |
| --- | --- | --- |
| `query` | Meeting name, tags, calendar title, AI description, and summary body | Full-text search. Every token must match somewhere across those fields; only the last token matches as a prefix. Needs 2 or more characters and at most 16 tokens. Ranked by title, then tags, calendar, description, and summary. Transcripts and Project names are not searched. |
| `simple: true` | The same fields, as a literal substring | Use for codes, ticket numbers, version strings, or mixed scripts that tokenization splits. |
| `ical_uid` | Meetings linked to the same calendar event, including every occurrence of a recurring series | The strongest link between Meetings. `recurrence_id` tells occurrences apart. |
| `attendee` | Part of an invited attendee's name or email on the linked calendar event, case-insensitive | Meetings without a calendar event never match. The calendar owner is not an attendee. An email domain such as `@example.com` finds everyone from one organization. |
| `project_id` | Meetings directly in that Project | Subprojects are not included; query each child from `query_projects` too. |
| `project` | Project by name | Resolve with `query_projects` and use `project_id` when names are ambiguous. |
| `created_from` / `created_before` | Meeting creation time, ISO 8601 date-time | Convert relative periods ("last week") to absolute timestamps with the user's time zone. |
| `limit`, `cursor` | Paging, up to 100 per page | Cursors are opaque; pass them back unchanged with the same filters. |
| `server_cursor` | Continuation of Server results in `server` | Independent of `cursor`. |

`query_screenshots` searches detected on-screen text and AI captions, and lists a Meeting's screenshots in time order
when given `meeting_id` without `query`.

## Scenarios

| Request | First call | Then |
| --- | --- | --- |
| "When did we talk about X?" | `query_meetings` with 1 to 3 distinctive keywords | `get_meetings` on the top hits; confirm wording in the transcript |
| History of a recurring Meeting, or preparing for its next occurrence | `get_meetings` on a known occurrence to read its `ical_uid` | `query_meetings` with that `ical_uid`; read the latest summaries in order to see what carried over |
| A series whose occurrence you do not know | `query_meetings` with the calendar title words | Take the `ical_uid` from a hit and switch to the row above |
| Meetings with a person | `query_meetings` with `attendee` set to the name or email | Add `created_from` for recent ones, or `query` for a topic |
| Meetings with a company | `query_meetings` with `attendee` set to `@domain` | Also check `query_projects` for the customer's Project and its subprojects |
| Everything about a customer or project | `query_projects` with the name | `query_meetings` with each `project_id` (root and children), plus dates if the user gave a period |
| What happened in a period | `query_meetings` with `created_from` / `created_before` and `limit: 100` | Follow every cursor; group by Project or series before reading summaries |
| Exact quote or who said something | Find candidate Meetings by topic first | `get_meeting_transcript` around the summary's time reference |
| Something shown on a slide or screen | `query_screenshots` with the visible text | `get_screenshots` for the image; `get_meetings` for the surrounding discussion |
| A Meeting in progress | `query_meetings` and pick `is_recording: true` | `get_meeting_transcript`, then repeat with `after` set to `next_after` and `wait: true` to follow new speech |

Combine filters freely: `ical_uid` with `created_from` for recent occurrences only, `attendee` with `query` for a topic
with one person, `project_id` with `query` for a topic inside a Project.

## Fallback ladder for empty results

1. Remove tokens. Every token must match, so a long query fails when one word is missing.
2. Try other wording: the other language the team uses, the product's official name, an abbreviation or its expansion.
3. Switch to `simple: true` for codes and mixed scripts.
4. Search screenshots with the same words; the topic may appear only on screen.
5. Drop `query` and filter by `attendee`, `project_id`, or dates, then scan names and descriptions.
6. Remember what is never searched: transcript text and Project names. A topic mentioned only in passing may be absent
   from the summary.

## Reading economy

- Metadata first, summaries second, transcripts and images last.
- `get_meetings` takes at most 5 IDs; request fewer if a response is too large.
- `get_meeting_transcript` returns up to 500 segments per page; narrow with elapsed seconds before paging a whole Meeting.
- `has_summary: false` Meetings have no summary to read; note them instead of reading their transcripts by default.
