import SwiftUI

struct TranscriptTabView<Header: View, Footer: View>: View {
    @ObservedObject var store: TranscriptStore
    let showsTranslatedText: Bool
    let retryInitialMeetingLoad: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    @AppStorage(DahliaTypography.baseSizeUserDefaultsKey) private var interfaceTextSize = Int(DahliaTypography.defaultBaseSize)
    @State private var pageLoadTask: Task<Void, Never>?
    @State private var scrollRequest: (token: Int, edge: TranscriptWebSurface.Edge)?

    private var showsTranscriptContent: Bool {
        !store.isLoadingInitialPage && !(store.segments.isEmpty && store.pageLoadError == nil)
    }

    var body: some View {
        // The rows render in a web view so their layout runs in the WebContent process; the header stays native above it.
        VStack(spacing: 0) {
            Group {
                header
                if showsTranscriptContent { transcriptBanners }
            }
            .frame(maxWidth: DahliaDesign.mainContentMaxWidth)
            .frame(maxWidth: .infinity)
            if store.isLoadingInitialPage {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !showsTranscriptContent {
                ContentUnavailableView {
                    Label(L10n.transcript, systemImage: "waveform.badge.microphone")
                } description: {
                    Text(L10n.transcriptEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptWebSurface(
                    contentID: store.contentID,
                    segments: store.segments,
                    recordingSessions: store.recordingSessions,
                    timeBase: store.timeBase,
                    showsTranslatedText: showsTranslatedText,
                    hasEarlier: store.hasEarlierSegments,
                    hasLater: store.hasLaterSegments,
                    baseSize: DahliaTypography.baseSizeOptions.contains(interfaceTextSize)
                        ? CGFloat(interfaceTextSize) : DahliaTypography.defaultBaseSize,
                    scrollRequest: scrollRequest,
                    onRequestPage: loadPage,
                    onFollowChange: { store.setFollowingLatest($0) }
                )
            }
            footer
                .frame(maxWidth: DahliaDesign.mainContentMaxWidth)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: showsTranscriptContent, initial: true) { _, shows in
            if shows { showStart() }
        }
        .onDisappear {
            pageLoadTask?.cancel()
        }
    }

    private var transcriptBanners: some View {
        VStack(spacing: 0) {
            if let pageLoadError = store.pageLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .dahliaFixedSymbol()
                        .foregroundStyle(.orange)
                    Text(L10n.transcriptLoadFailed(pageLoadError))
                        .font(.dahliaBody)
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
                        .font(.dahliaBody)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
            }
        }
    }

    /// Open at the page top like the other tabs instead of jumping to the latest segment.
    private func showStart() {
        store.setFollowingLatest(false)
        scroll(to: .top)
        guard store.hasEarlierSegments, pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor in
            await store.loadEarliest()
            pageLoadTask = nil
        }
    }

    private func scroll(to edge: TranscriptWebSurface.Edge) {
        scrollRequest = ((scrollRequest?.token ?? 0) + 1, edge)
    }

    private func loadPage(_ edge: TranscriptWebSurface.Edge) {
        guard pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor in
            _ = switch edge {
            case .top: await store.loadEarlier()
            case .bottom: await store.loadLater()
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
                store.setFollowingLatest(true)
                scroll(to: .bottom)
            }
            pageLoadTask = nil
        }
    }
}
