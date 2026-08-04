# 0022: Unify main-window navigation and meeting content

Date: 2026-08-04

Status: Accepted

## Context

Dahlia's schedule, meetings, Projects, customer intelligence, evidence, and analysis grew as separate tabs or windows. The resulting toolbar mixed navigation, window launchers, contextual actions, and recording controls. Summary transcript references also pointed only at the bounded in-memory transcript projection, so references outside the current page could not be followed reliably.

The default 1,120 pt window cannot show a section column, meeting list, meeting body, and inspector at once without making every content surface too narrow.

## Decision

The main window uses a two-column global navigation shell:

```text
Section / Project | Active workspace
```

Meeting and Project workspaces subdivide the active workspace into a meeting list and meeting detail. Schedule uses the full active workspace, while Organizations provides its own master-detail navigation. This avoids empty intermediate columns on destinations that do not have a list-detail relationship.

Schedule, Meetings, Projects, and Organizations are first-class main-window sections. Selecting a Project scopes the meeting list and its search to that Project. Project management remains a dedicated management surface because deletion and Summary-file movement are multi-record operations. Organizations remain available in a detached window as well as the main window.

Meeting body navigation contains Summary, Notes, Screenshots, Transcript, and beta-gated Conversation Analytics as peer destinations. These are alternative full-width views of one meeting, not persistent context that must remain beside the summary. A summary transcript reference selects the Transcript destination, resolves against SQLite using meeting-wide elapsed time, loads a bounded page around the resolved segment, and scrolls by segment ID. References retain their existing `HH:mm:ss` serialized form.

The window toolbar contains global commands, including Settings and Organization history navigation. Summary generation and sharing stay beside the meeting tabs because they act on the selected meeting rather than the application as a whole.

Recording actions follow one pure state and placement model. The primary toolbar position is stable. While a different meeting is displayed it returns to the recording meeting, and a separate stop action remains reachable. If the sidebar is hidden, the toolbar owns that stop action.

## Recording command contract

| State | Primary command |
| --- | --- |
| Not recording, schedule | Create and record a new meeting |
| Not recording, one meeting | Append to the selected meeting |
| Not recording, multiple meetings | Create and record a new meeting |
| Recording, recording meeting visible | Stop |
| Recording, another meeting visible | Return to the recording meeting |
| Vault/permissions/preparation unavailable | Disabled with the existing availability reason |

Every recording state places at least one immediate stop action in the main window. With a visible sidebar it is in the global recording indicator or the recording meeting header. With a hidden sidebar it is in the toolbar.

## Consequences

Navigation context is visible before actions are taken, pages use only the columns their task requires, and meeting content receives the full detail width. Global and meeting-specific commands occupy separate regions. The main window owns more state, but that state is a small value model and can be reset deterministically on Vault changes. SQLite remains the transcript source of truth and only bounded pages enter the UI projection.
