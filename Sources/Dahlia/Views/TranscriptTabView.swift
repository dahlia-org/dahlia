import SwiftUI

struct TranscriptTabView: View {
    private enum ScrollMetrics {
        static let bottomAnchorID = "transcript-bottom"
        static let followThreshold: CGFloat = 32
        static let loadMoreThreshold: CGFloat = 24
    }

    private struct EdgeProximity: Equatable {
        let isNearBottom: Bool
        let isNearTop: Bool
    }

    private enum WindowMetrics {
        /// SwiftUI の差分計算量を抑え、録音中の MainActor 占有時間に上限を設ける。
        static let initialWindowSize = 100
        static let loadMoreCount = 50
    }

    @ObservedObject var store: TranscriptStore
    let isListening: Bool
    let showsRecordingIndicator: Bool
    let showsTranslatedText: Bool
    let batchTranscriptionState: BatchTranscriptionState?
    let confirmBatchTranscription: () -> Void
    let retryBatchTranscription: () -> Void
    let discardFailedBatchTranscription: () -> Void

    @State private var shouldFollowLatest = true
    @State private var windowSize = WindowMetrics.initialWindowSize
    @State private var didCompleteInitialBottomScroll = false
    /// 上端到達時の onAppear が連射しないようにする単発フラグ。
    /// 一度 false に倒したら、ユーザーが上端から離れた瞬間 (`!isNearTop`) にのみ再アームする。
    /// Spinner が表示領域に留まり続けるケースで誤って再ロードが走るのを防ぐ。
    @State private var canLoadMoreFromTop = true
    /// resetWindowAndScrollToBottom 中の deferred scroll を保持し、リセット連発時に古い Task を cancel する。
    @State private var pendingScrollTask: Task<Void, Never>?

    /// ForEach の ID 照合対象を制限するため、末尾 windowSize 件のみ返す。
    private var windowedSegments: ArraySlice<TranscriptSegment> {
        let segments = store.segments
        guard segments.count > windowSize else { return segments[...] }
        return segments.suffix(windowSize)
    }

    /// 配列確保なしでウィンドウ内のセグメント数を返す。
    private var windowedSegmentCount: Int {
        min(store.segments.count, windowSize)
    }

    private var hasMoreAbove: Bool {
        store.segments.count > windowSize
    }

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

            if store.segments.isEmpty, !isListening || batchTranscriptionState != nil {
                ContentUnavailableView {
                    Label(L10n.transcript, systemImage: "waveform.badge.microphone")
                } description: {
                    Text(L10n.transcriptEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptScrollView
            }
        }
    }

    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if hasMoreAbove {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .onAppear {
                                loadMoreSegmentsIfNeeded()
                            }
                    }

                    let timeBase = store.timeBase
                    let recordingSessions = store.recordingSessions
                    ForEach(windowedSegments) { segment in
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

                    Color.clear
                        .frame(height: 1)
                        .id(ScrollMetrics.bottomAnchorID)
                }
                .padding(8)
            }
            .onAppear {
                resetWindowAndScrollToBottom(using: proxy)
            }
            .onChange(of: store.segments.first?.id) { _, _ in
                resetWindowAndScrollToBottom(using: proxy)
            }
            .onScrollGeometryChange(for: EdgeProximity.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return EdgeProximity(
                    isNearBottom: distanceFromBottom <= ScrollMetrics.followThreshold,
                    isNearTop: geometry.contentOffset.y <= ScrollMetrics.loadMoreThreshold
                )
            } action: { _, proximity in
                shouldFollowLatest = proximity.isNearBottom
                if !proximity.isNearTop {
                    canLoadMoreFromTop = true
                }
            }
            .onChange(of: windowedSegmentCount) { oldCount, newCount in
                guard newCount > oldCount, shouldFollowLatest else { return }
                scrollToBottom(using: proxy)
            }
            .onChange(of: shouldFollowLatest) { _, isFollowing in
                if isFollowing {
                    windowSize = WindowMetrics.initialWindowSize
                }
            }
        }
    }

    private func loadMoreSegmentsIfNeeded() {
        guard didCompleteInitialBottomScroll, !shouldFollowLatest, canLoadMoreFromTop else { return }
        canLoadMoreFromTop = false
        windowSize = min(windowSize + WindowMetrics.loadMoreCount, store.segments.count)
    }

    private func resetWindowAndScrollToBottom(using proxy: ScrollViewProxy) {
        didCompleteInitialBottomScroll = false
        canLoadMoreFromTop = true
        shouldFollowLatest = true
        windowSize = WindowMetrics.initialWindowSize

        // 連続リセット時に古い Task が新しい状態を上書きしないよう、pending Task を cancel する。
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            // LazyVStack の初期レイアウト確定後にスクロールするため、1 ターン譲る。
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToBottom(using: proxy)
            didCompleteInitialBottomScroll = true
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(ScrollMetrics.bottomAnchorID, anchor: .bottom)
        }
    }
}
