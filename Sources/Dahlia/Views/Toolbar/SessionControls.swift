import DahliaRuntimeSupport
import SwiftUI

struct RecordButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    @State private var isHovered = false

    private var state: RecordingCommandState {
        RecordingCommandState(
            isListening: viewModel.isListening,
            canStartNewMeeting: recordingCoordinator.canStartNewMeeting
        )
    }

    var body: some View {
        Button(label, systemImage: iconName, action: toggle)
            .labelStyle(.titleAndIcon)
            .font(.title3)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                    .fill(.white.opacity(isHovered && state.isEnabled ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
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

struct GenerateSummaryHeaderButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    @State private var isConfirmationPresented = false

    private var isGeneratingCurrentMeeting: Bool {
        viewModel.isSummaryGenerating
    }

    private var isGenerateSummaryEnabled: Bool {
        !isGeneratingCurrentMeeting && viewModel.canGenerateSummary
    }

    var body: some View {
        Button(action: presentConfirmation) {
            Label {
                Text(isGeneratingCurrentMeeting ? L10n.generatingSummary : L10n.generateSummary)
            } icon: {
                if isGeneratingCurrentMeeting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.purple)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(viewModel.canGenerateSummary ? Color.purple : DahliaDesign.secondaryTextColor)
                }
            }
        }
        .modifier(SummaryHeaderButtonModifier(isEnabled: isGenerateSummaryEnabled))
        .disabled(!isGenerateSummaryEnabled)
        .help(isGeneratingCurrentMeeting ? L10n.generatingSummary : L10n.generateSummary)
        .sheet(isPresented: $isConfirmationPresented) {
            SummaryGenerationConfirmationView(
                projects: sidebarViewModel.flatProjects,
                initialProjectId: viewModel.currentProjectId,
                onGenerate: generateSummary
            )
        }
    }

    private func presentConfirmation() {
        isConfirmationPresented = true
    }

    private func generateSummary(options: SummaryGenerationOptions, projectId: UUID?) -> String? {
        if let error = viewModel.assignCurrentMeetingProject(projectId) {
            return error
        }
        guard !viewModel.triggerManualSummary(options: options) else { return nil }
        return viewModel.isSummaryGenerating ? nil : L10n.summaryGenerationFailed
    }
}

struct ShareSummaryHeaderButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            Label {
                Text(L10n.share)
            } icon: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(viewModel.canShareCurrentSummary ? Color.accentColor : DahliaDesign.secondaryTextColor)
            }
        }
        .modifier(SummaryHeaderButtonModifier(isEnabled: viewModel.canShareCurrentSummary))
        .disabled(!viewModel.canShareCurrentSummary)
        .help(L10n.shareSummary)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            SummarySharePopover(viewModel: viewModel) {
                isPopoverPresented = false
            }
        }
    }
}

private struct SummaryHeaderButtonModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
            .background(
                isHovered && isEnabled ? DahliaDesign.contentHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}

private struct SummarySharePopover: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
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
                    RoundedRectangle(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
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
                        .font(.body)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
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
                    .font(.callout)
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
        mainWindowNavigation.openSettings(category: .cloudStorage)
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
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
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
                RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                    .fill(isHovering ? DahliaDesign.contentHighlightColor : .clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}
