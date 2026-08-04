# 0022: Unify main-window navigation and evidence inspection

Date: 2026-08-04

Status: Accepted

## Context

Dahlia's schedule, meetings, Projects, customer intelligence, evidence, and analysis grew as separate tabs or windows. The resulting toolbar mixed navigation, window launchers, contextual actions, and recording controls. Summary transcript references also pointed only at the bounded in-memory transcript projection, so references outside the current page could not be followed reliably.

The default 1,120 pt window cannot show a 240 pt section column, 300 pt meeting list, 500 pt body, and 300 pt inspector at once.

## Decision

The main window uses a Mail-style three-column navigation shell:

```text
Section / Project | Meeting list | Summary or Notes | Evidence / Analysis inspector
```

The fourth region is a SwiftUI inspector rather than another navigation column. At wide widths all regions may be visible. As width decreases, the section/Project column collapses first, then the inspector becomes an explicitly selected destination, and finally the meeting list and detail use the platform navigation transition.

Schedule, Meetings, Projects, and Organizations are first-class main-window sections. Selecting a Project scopes the meeting list and its search to that Project. Project management remains a dedicated management surface because deletion and Summary-file movement are multi-record operations. Organizations remain available in a detached window as well as the main window.

Meeting body navigation contains only Summary and Notes. Transcript and Screenshots belong to an Evidence inspector; conversation analytics belongs to an Analysis inspector. A summary transcript reference resolves against SQLite using meeting-wide elapsed time, loads a bounded page around the resolved segment, and scrolls by segment ID. References retain their existing `HH:mm:ss` serialized form.

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

Navigation context is visible before actions are taken, related controls are grouped by region, and evidence can remain beside the summary. The main window owns more state, but that state is a small value model and can be reset deterministically on Vault changes. SQLite remains the transcript source of truth and only bounded pages enter the UI projection.
