import SwiftUI

struct RecordToolbarButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    private var state: RecordingCommandState {
        RecordingCommandState(
            isListening: viewModel.isListening,
            canStartNewMeeting: recordingCoordinator.canStartNewMeeting
        )
    }

    var body: some View {
        Button(action: toggle) {
            Label(label, systemImage: iconName)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!state.isEnabled)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help(label)
        .accessibilityHint(L10n.recordingCommandHint)
    }

    private func toggle() {
        if viewModel.isListening {
            recordingCoordinator.stopRecording()
            return
        }

        if let selectedMeetingId = sidebarViewModel.selectedMeetingId {
            recordingCoordinator.startRecording(appendingTo: selectedMeetingId)
        } else {
            recordingCoordinator.startNewMeeting()
        }
    }

    private var iconName: String {
        state.action == .stop ? "stop.fill" : "record.circle"
    }

    private var label: String {
        state.action == .stop ? L10n.stopRecording : L10n.startRecording
    }
}

struct GenerateSummaryToolbarButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    @State private var isConfirmationPresented = false

    private var isGeneratingCurrentMeeting: Bool {
        viewModel.summaryGeneratingMeetingId == viewModel.currentMeetingId
    }

    var body: some View {
        Button(action: presentConfirmation) {
            Label {
                Text(isGeneratingCurrentMeeting ? L10n.generatingSummary : L10n.generateSummary)
            } icon: {
                if isGeneratingCurrentMeeting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .disabled(isGeneratingCurrentMeeting || !viewModel.canGenerateSummary)
        .help(isGeneratingCurrentMeeting ? L10n.generatingSummary : L10n.generateSummary)
        .sheet(isPresented: $isConfirmationPresented) {
            SummaryGenerationConfirmationView(onGenerate: generateSummary)
        }
    }

    private func presentConfirmation() {
        isConfirmationPresented = true
    }

    private func generateSummary(options: SummaryGenerationOptions) {
        viewModel.triggerManualSummary(options: options)
    }
}

struct ShareSummaryToolbarButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            Label {
                Text(L10n.shareSummary)
            } icon: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(viewModel.canShareCurrentSummary ? Color.accentColor : .secondary)
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(!viewModel.canShareCurrentSummary)
        .help(L10n.shareSummary)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            SummarySharePopover(viewModel: viewModel) {
                isPopoverPresented = false
            }
        }
    }
}

private struct SummarySharePopover: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var viewModel: CaptionViewModel
    @ObservedObject private var driveStore = GoogleDriveStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isGoogleDocsExportRunning = false
    @State private var exportFolderAlertMessage = ""
    @State private var isShowingExportFolderAlert = false
    let dismiss: () -> Void

    private var title: String {
        viewModel.currentSummaryDocument?.title.nilIfBlank ?? L10n.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(L10n.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()
                .padding(.horizontal, 20)

            VStack(spacing: 2) {
                SummarySharePopoverRow(
                    title: L10n.exportToGoogleDocs,
                    systemImage: "doc.badge.arrow.up",
                    isDisabled: isGoogleDocsExportRunning || driveStore.isBusy || !canExportToGoogleDocs,
                    isLoading: isGoogleDocsExportRunning || driveStore.isBusy
                ) {
                    exportToGoogleDocs()
                }
                SummarySharePopoverRow(title: L10n.copySummaryForGoogleDocs, systemImage: "doc.richtext") {
                    copySummary(for: .googleDocs)
                }
                SummarySharePopoverRow(title: L10n.copySummaryForSlack, systemImage: "message") {
                    copySummary(for: .slack)
                }
                if needsGoogleDriveSetup {
                    SummarySharePopoverRow(
                        title: L10n.openCloudStorageSettings,
                        systemImage: "gearshape"
                    ) {
                        openCloudStorageSettings()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let errorMessage = googleDocsErrorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 320)
        .padding(.vertical, 8)
        .onAppear {
            guard let message = driveStore.exportFolderErrorMessage else { return }
            exportFolderAlertMessage = message
            isShowingExportFolderAlert = true
        }
        .onChange(of: driveStore.exportFolderErrorMessage) { _, message in
            guard let message else { return }
            exportFolderAlertMessage = message
            isShowingExportFolderAlert = true
        }
        .alert(L10n.googleDriveExportFolderConfigurationFailed, isPresented: $isShowingExportFolderAlert) {
            Button(L10n.close, role: .cancel) {}
            Button(L10n.openCloudStorageSettings, action: openCloudStorageSettings)
        } message: {
            Text(exportFolderAlertMessage)
        }
    }

    private func copySummary(for destination: SummaryShareRenderer.Destination) {
        viewModel.copyCurrentSummary(for: destination)
        dismiss()
    }

    private var googleDocsErrorMessage: String? {
        viewModel.googleDocsExportError ?? driveStore.exportFolderErrorMessage ?? driveStore.lastErrorMessage
    }

    private var canExportToGoogleDocs: Bool {
        guard driveStore.isAuthorized,
              driveStore.exportFolderErrorMessage == nil,
              let accountID = driveStore.account?.id else { return false }
        return settings.googleDriveExportFolderID(forAccountID: accountID) != nil
    }

    private var needsGoogleDriveSetup: Bool {
        !driveStore.isBusy && !canExportToGoogleDocs
    }

    private func exportToGoogleDocs() {
        guard !isGoogleDocsExportRunning else { return }
        isGoogleDocsExportRunning = true
        Task { @MainActor in
            defer { isGoogleDocsExportRunning = false }
            guard canExportToGoogleDocs else { return }
            if await viewModel.exportCurrentSummaryToGoogleDocs() {
                dismiss()
            }
        }
    }

    private func openCloudStorageSettings() {
        UserDefaults.standard.set(
            SettingsCategory.cloudStorage.rawValue,
            forKey: SettingsNavigation.selectedCategoryDefaultsKey
        )
        openSettings()
        dismiss()
    }
}

private struct SummarySharePopoverRow: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}
