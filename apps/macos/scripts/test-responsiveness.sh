#!/bin/bash
# Run the suites that pin the bounded-projection and lane-isolation contracts in ARCHITECTURE.md
# ("UI and Interaction Responsiveness" and "Conformance Status"). Extra arguments go to `swift test`.
# Add a suite here when it pins one of those contracts.
set -euo pipefail

cd "$(dirname "$0")/../../.."
if [[ -z "${DEVELOPER_DIR:-}" ]] \
    && [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] \
    && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

suites=(
    AgentLearningTests                  # bounded settings previews preserve the complete learning ledger
    AgentSkillSettingsTests             # skill path resolution never blocks MainActor
    TranscriptionEventPipelineTests       # the UI lane never gates audio acceptance or durable persistence
    TranscriptionEventRouterTests         # realtime, batch, and live-caption projections stay separate
    LiveCaptionEventRelayTests            # bounded latest-wins relay for batch live captions
    LiveCaptionStoreTests                 # stale sessions cannot reach the caption projection
    LiveSubtitleOverlayCoordinatorTests   # bounded overlay publish cadence
    TranscriptPagingTests                 # bounded TranscriptStore window over SQLite
    MeetingSidebarRepositoryTests         # indexed per-project candidates stay bounded as history grows
    MeetingSidebarProjectionBudgetTests   # sidebar projection limit
    SummaryHistoryTests                   # paged summary history and stale version selection
    ChatRunTests                         # bounded run subscriptions and history projections
    CodexChatSubscriptionTests           # dropped readers reattach or reload completed history
    CodexChatHistoryPagingTests           # bounded initial chat history and stale page cancellation
    CodexChatThinkingPresentationTests    # immediate submission acknowledgement before Pi startup
    CodexChatStreamingUpdateLimiterTests  # coalesced streaming updates
    CodexChatMarkdownProjectionModelTests # latest-wins Markdown projection
    CodexChatMarkdownCacheTests           # completed-cache count and byte limits
    CodexChatSlashCommandTests            # bounded slash command candidate projection
    GoogleDriveBackupModelTests           # account switches discard stale cloud backup lists
    ScreenshotImageLoaderTests            # interactive decode never waits behind cacheable decode
    TranscriptWebSurfaceTests             # transcript rows render out of process and recover from a stalled page
    MainActorHangMonitorTests             # stall reports carry only fixed tags
)
filter="$(IFS='|'; echo "${suites[*]}")"
exec swift test --filter "(${filter})" "$@"
