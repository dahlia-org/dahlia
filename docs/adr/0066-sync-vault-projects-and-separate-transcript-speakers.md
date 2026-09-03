# ADR-0066: Sync Vault Projects and Separate Transcript Speakers

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0056, ADR-0058, ADR-0059, ADR-0062

## Context

Meeting sync previously created a Server Vault only as a side effect of uploading a meeting. It therefore could not preserve a Vault name, an empty Vault, or the Desktop Project hierarchy. Transcript `speaker_label` also carried the recording route (`mic` or `system`), preventing that field from representing a future diarized speaker.

## Decision

- Desktop sends an owner-only Vault manifest before meeting uploads. It contains the Vault name and the complete two-level Project hierarchy; the last accepted manifest replaces the previous Project set.
- Server stores Projects in `core.projects`. They inherit Vault permissions, are exposed for hierarchy browsing and explicit meeting filtering, and are not included in full-text or vector search.
- Meetings may reference a Project in the same Vault. Removing a Project clears that reference instead of deleting the meeting.
- Transcript `audio_source` records `mic` or `system`. Nullable `speaker_label` is reserved for a human or diarized speaker identity and is currently unset.
- The Desktop database uses a forward migration that moves existing routing values from `speakerLabel` to `audioSource` and clears `speakerLabel`. The unreleased Server wire contract has no compatibility path for the old field meaning.

## Consequences

Empty Vaults and Project-only changes can be synchronized independently of meetings. Server REST, Private Web, and MCP can browse Projects and filter meetings by a Project subtree without expanding the search projection. Recording-source behavior remains stable while the transcript model gains a distinct place for future speaker attribution.
