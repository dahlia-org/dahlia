import SwiftUI

struct TranscriptTabView: View {
    private static let prefetchDistance = 30

    @ObservedObject var store: TranscriptStore
    let isListening: Bool
    let showsRecordingIndicator: Bool
    let showsTranslatedText: Bool
    let batchTranscriptionState: BatchTranscriptionState?
    let confirmBatchTranscription: () -> Void
    let retryBatchTranscription: () -> Void
    let discardFailedBatchTranscription: () -> Void
    let retryInitialMeetingLoad: () -> Void

    @State private var scrollPosition = ScrollPosition(idType: TranscriptSegment.ID.self)
    @State private var isFollowingLatest = true
    @State private var pageLoadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let batchTranscriptionState {
                BatchTranscriptionStatusView(
                    state: batchTranscriptionState,
                    confirm: confirmBatchTranscription,
                    retry: retryBatchTranscription,
                    discard: discardFailedBatchTranscription
                )
            }

            if store.isLoadingInitialPage {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.segments.isEmpty,
                      store.pageLoadError == nil,
                      !isListening || batchTranscriptionState != nil {
                ContentUnavailableView {
                    Label(L10n.transcript, systemImage: "waveform.badge.microphone")
                } description: {
                    Text(L10n.transcriptEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptContent
            }
        }
        .onDisappear {
            pageLoadTask?.cancel()
        }
    }

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            if let pageLoadError = store.pageLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.transcriptLoadFailed(pageLoadError))
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button(L10n.retry) {
                        if store.requiresFullMeetingReload {
                            retryInitialMeetingLoad()
                        } else {
                            retryPageLoad()
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            if store.hasNewerSegments {
                Button {
                    loadLatest()
                } label: {
                    Label(L10n.newerTranscriptAvailable, systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let timeBase = store.timeBase
                    let recordingSessions = store.recordingSessions
                    ForEach(store.segments) { segment in
                        TranscriptRowView(
                            segment: segment,
                            timestamp: Formatters.elapsedHHmmss(
                                at: segment.startTime,
                                sessionId: segment.sessionId,
                                sessions: recordingSessions,
                                fallbackTimeBase: timeBase
                            ),
                            showsTranslatedText: showsTranslatedText,
                            allowsTextSelection: !isListening
                        )
                        .equatable()
                        .id(segment.id)
                    }

                    if showsRecordingIndicator {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text(L10n.recognizing)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, 68)
                    }
                }
                .scrollTargetLayout()
                .padding(8)
            }
            .scrollPosition($scrollPosition)
            .onScrollTargetVisibilityChange(idType: TranscriptSegment.ID.self, threshold: 0.1) { ids in
                updateVisibleSegments(ids)
            }
            .onAppear {
                scrollToLatest()
            }
            .onChange(of: store.latestConfirmedID) { _, _ in
                guard isFollowingLatest, !store.hasLaterSegments else { return }
                scrollToLatest()
            }
        }
    }

    private func updateVisibleSegments(_ ids: [TranscriptSegment.ID]) {
        let indexesByID = Dictionary(uniqueKeysWithValues: store.segments.enumerated().map { ($0.element.id, $0.offset) })
        let visible = ids.compactMap { id in indexesByID[id].map { (id, $0) } }
        guard let first = visible.min(by: { $0.1 < $1.1 }),
              let last = visible.max(by: { $0.1 < $1.1 }) else { return }

        let followsLatest = !store.hasLaterSegments
            && last.1 >= max(0, store.segments.count - 2)
        isFollowingLatest = followsLatest
        store.setFollowingLatest(followsLatest)

        if first.1 <= Self.prefetchDistance, store.hasEarlierSegments {
            loadPage(.earlier, anchorID: first.0)
        } else if last.1 >= store.segments.count - Self.prefetchDistance - 1,
                  store.hasLaterSegments {
            loadPage(.later, anchorID: last.0)
        }
    }

    private enum PageEdge: Equatable {
        case earlier
        case later
    }

    private func loadPage(_ edge: PageEdge, anchorID: TranscriptSegment.ID) {
        guard pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor in
            let didLoad = switch edge {
            case .earlier:
                await store.loadEarlier()
            case .later:
                await store.loadLater()
            }
            guard !Task.isCancelled else {
                pageLoadTask = nil
                return
            }
            if didLoad {
                restorePosition(to: anchorID, edge: edge)
            }
            pageLoadTask = nil
        }
    }

    private func retryPageLoad() {
        guard pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor in
            _ = await store.retryPageLoad()
            pageLoadTask = nil
        }
    }

    private func loadLatest() {
        guard pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor in
            if await store.reloadLatest() {
                isFollowingLatest = true
                store.setFollowingLatest(true)
                scrollToLatest()
            }
            pageLoadTask = nil
        }
    }

    private func restorePosition(to id: TranscriptSegment.ID, edge: PageEdge) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(
                id: id,
                anchor: edge == .earlier ? .top : .bottom
            )
        }
    }

    private func scrollToLatest() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}
