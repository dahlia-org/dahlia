import SwiftUI

struct TranscriptTabView<Header: View, Footer: View>: View {
    private var prefetchDistance: Int { 30 }

    @ObservedObject var store: TranscriptStore
    let allowsTextSelection: Bool
    let showsTranslatedText: Bool
    let retryInitialMeetingLoad: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    @State private var scrollPosition = ScrollPosition(idType: TranscriptSegment.ID.self)
    @State private var isFollowingLatest = true
    @State private var pageLoadTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if store.isLoadingInitialPage {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.segments.isEmpty,
                          store.pageLoadError == nil {
                    ContentUnavailableView {
                        Label(L10n.transcript, systemImage: "waveform.badge.microphone")
                    } description: {
                        Text(L10n.transcriptEmpty)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcriptContent
                }
                footer
            }
            .frame(maxWidth: DahliaDesign.mainContentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .onScrollTargetVisibilityChange(idType: TranscriptSegment.ID.self, threshold: 0.1) { ids in
            updateVisibleSegments(ids)
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
                        .dahliaFixedSymbol()
                        .foregroundStyle(.orange)
                    Text(L10n.transcriptLoadFailed(pageLoadError))
                        .font(.callout)
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
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }

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
                        allowsTextSelection: allowsTextSelection
                    )
                    .equatable()
                    .id(segment.id)
                }
            }
            .scrollTargetLayout()
            .padding(DahliaDesign.tabContentInset)
            .onAppear {
                scrollToLatest(in: &scrollPosition)
            }
            .onChange(of: store.latestConfirmedID) { _, _ in
                guard isFollowingLatest, !store.hasLaterSegments else { return }
                scrollToLatest(in: &scrollPosition)
            }
        }
    }

    private func updateVisibleSegments(_ ids: [TranscriptSegment.ID]) {
        let indexesByID = Dictionary(uniqueKeysWithValues: store.segments.enumerated().map { ($0.element.id, $0.offset) })
        let visible = ids.compactMap { id in indexesByID[id].map { (id, $0) } }
        if visible.isEmpty, scrollPosition.isPositionedByUser {
            isFollowingLatest = false
            store.setFollowingLatest(false)
        }
        guard let first = visible.min(by: { $0.1 < $1.1 }),
              let last = visible.max(by: { $0.1 < $1.1 }) else { return }

        let followsLatest = !store.hasLaterSegments
            && last.1 >= max(0, store.segments.count - 2)
        isFollowingLatest = followsLatest
        store.setFollowingLatest(followsLatest)

        if first.1 <= prefetchDistance, store.hasEarlierSegments {
            loadPage(.earlier, anchorID: first.0)
        } else if last.1 >= store.segments.count - prefetchDistance - 1,
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
                scrollToLatest(in: &scrollPosition)
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

    func scrollToLatest(in position: inout ScrollPosition) {
        guard let latestID = store.segments.last?.id else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(id: latestID, anchor: .bottom)
        }
    }
}
