import DahliaRuntimeSupport
import GRDB
import SwiftUI

struct SummaryTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    let meetingID: UUID?
    let dbQueue: DatabaseQueue?
    @State private var history = SummaryHistoryModel()
    @State private var reload = 0
    @State private var loadMore = 0
    let document: SummaryDocument?
    let hasSummary: Bool
    /// False for a Workspace with a folder: its exported file follows only the latest summary.
    let showsHistory: Bool
    let canPromote: Bool
    let onPromoted: (SummaryDocument) -> Void
    let openScreenshot: (UUID, CGImage) -> Void
    let transcriptText: (TranscriptReference) -> String?

    private var displayedDocument: SummaryDocument? {
        history.selectedVersion == nil ? document : history.document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
            if hasSummary, showsHistory {
                HStack {
                    Picker(L10n.summaryVersion, selection: $history.selectedVersion) {
                        Text(L10n.summaryCurrentVersion).font(.dahliaBody).tag(nil as Int?)
                        if let selected = history.selectedVersion, !history.versions.contains(where: { $0.version == selected }) {
                            Text("v\(selected)").font(.dahliaBody).tag(Optional(selected))
                        }
                        ForEach(history.versions) { version in
                            Text(
                                "v\(version.version) · \(version.savedAt.formatted(date: .abbreviated, time: .shortened))"
                                    + (version.version == history.currentVersion ? " · \(L10n.summaryCurrentVersion)" : "")
                            )
                            .font(.dahliaBody)
                            .tag(Optional(version.version))
                        }
                    }
                    .font(.dahliaBody)
                    .fixedSize()
                    .disabled(history.isPromoting)
                    SummaryGenerationDetailsView(metadata: displayedDocument?.metadata)
                        .id(history.selectedVersion)
                    if history.selectedVersion != nil, history.selectedVersion != history.currentVersion {
                        Image(systemName: "lock")
                            .font(.dahliaSecondary)
                            .foregroundStyle(.secondary)
                            .help(L10n.summaryReadOnlyVersion)
                            .accessibilityLabel(L10n.summaryReadOnlyVersion)
                        if canPromote {
                            Button(L10n.summaryPromoteVersion, systemImage: "arrow.up.doc") {
                                guard let meetingID, let dbQueue else { return }
                                Task {
                                    if let promoted = await history.promote(meetingID: meetingID, dbQueue: dbQueue) {
                                        onPromoted(promoted)
                                    }
                                }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(history.document == nil || history.isPromoting)
                            .dahliaHoverHelp(label: L10n.summaryPromoteVersion)
                        }
                    }
                    if history.nextCursor != nil {
                        Button(L10n.loadMore) { loadMore += 1 }
                            .disabled(history.isLoading || history.isPromoting)
                    }
                    if history.isLoading || history.isPromoting { ProgressView().controlSize(.small) }
                }
            }
            if let error = history.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.retry) { reload += 1 }
                }
            }
            if let displayedDocument, hasSummary || history.selectedVersion != nil {
                if history.selectedVersion != nil {
                    Text(displayedDocument.title).font(.dahliaTitle2)
                }
                SummaryDocumentView(
                    document: displayedDocument,
                    screenshotProvider: screenshot,
                    onOpenImage: openScreenshot,
                    transcriptTextProvider: transcriptText
                )
                .id(history.selectedVersion)
            } else if history.selectedVersion != nil, history.error == nil {
                ProgressView()
            } else if !hasSummary {
                ContentUnavailableView {
                    Label(L10n.summary, systemImage: "list.bullet.clipboard")
                } description: {
                    Text(L10n.noSummaryYet)
                }
            }
        }
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, DahliaDesign.tabContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: document) {
            if hasSummary, showsHistory, let meetingID, let dbQueue { await history.load(meetingID: meetingID, dbQueue: dbQueue) }
        }
        .onChange(of: showsHistory) { history.selectedVersion = nil }
        .task(id: history.selectedVersion) {
            if let meetingID, let dbQueue { await history.select(meetingID: meetingID, dbQueue: dbQueue) }
        }
        .task(id: loadMore) {
            guard loadMore > 0, let meetingID, let dbQueue else { return }
            await history.load(meetingID: meetingID, dbQueue: dbQueue, more: true)
        }
        .task(id: reload) {
            guard reload > 0, let meetingID, let dbQueue else { return }
            await history.load(meetingID: meetingID, dbQueue: dbQueue)
            await history.select(meetingID: meetingID, dbQueue: dbQueue)
        }
    }

    private func screenshot(for screenshotID: UUID) -> MeetingScreenshotRecord? {
        screenshotStore.records.first { $0.id == screenshotID }
    }
}
