import SwiftUI

struct UnprocessedRecordingsView: View {
    let items: [BackupPreflightItem]
    @ObservedObject var captionViewModel: CaptionViewModel
    let sidebarViewModel: SidebarViewModel
    @State private var pendingDiscardItem: BackupPreflightItem?

    var body: some View {
        Group {
            if items.isEmpty {
                emptyContent
            } else {
                List(items) { item in
                    LabeledContent {
                        actions(for: item)
                    } label: {
                        Text(item.meetingName)
                        Text(item.startedAt, format: .dateTime.year().month().day().hour().minute())
                        Text(item.statusDescription)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let error = sidebarViewModel.unprocessedRecordingsError {
                        errorBanner(error)
                    }
                }
                .padding(.top, DahliaDesign.detailTopPadding)
            }
        }
        .confirmationDialog(
            L10n.discardUnprocessedRecordingConfirmation,
            isPresented: Binding(
                get: { pendingDiscardItem != nil },
                set: { if !$0 { pendingDiscardItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.discardRecording, role: .destructive) {
                guard let item = pendingDiscardItem else { return }
                pendingDiscardItem = nil
                Task { await sidebarViewModel.discardUnprocessedRecording(item) }
            }
            Button(L10n.cancel, role: .cancel) { pendingDiscardItem = nil }
        } message: {
            Text(L10n.discardUnprocessedRecordingDescription)
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if sidebarViewModel.isLoadingUnprocessedRecordings {
            ProgressView()
        } else if let error = sidebarViewModel.unprocessedRecordingsError {
            ContentUnavailableView {
                Label(L10n.unprocessedRecordings, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.retry) {
                    Task { await sidebarViewModel.refreshUnprocessedRecordings() }
                }
            }
        } else {
            ContentUnavailableView(
                L10n.unprocessedRecordings,
                systemImage: "waveform.badge.checkmark",
                description: Text(L10n.noUnprocessedRecordingsDescription)
            )
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
            Spacer()
            Button(L10n.retry) {
                Task { await sidebarViewModel.refreshUnprocessedRecordings() }
            }
        }
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private func actions(for item: BackupPreflightItem) -> some View {
        HStack {
            if item.canStartTranscription {
                Button(item.state == .interrupted ? L10n.resumeBatchTranscription : L10n.transcribe) {
                    beginTranscription(item)
                }
                .buttonStyle(.borderedProminent)
            } else if item.isWorkInProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Button(L10n.discardRecording, role: .destructive) {
                pendingDiscardItem = item
            }
            .disabled(!item.canDiscard)
        }
    }

    private func beginTranscription(_ item: BackupPreflightItem) {
        guard let dbQueue = sidebarViewModel.dbQueue else { return }
        sidebarViewModel.selectMeeting(item.meetingId)
        Task {
            await captionViewModel.presentManualBatchTranscription(
                sessionId: item.sessionId,
                meetingId: item.meetingId,
                dbQueue: dbQueue
            )
        }
    }
}
