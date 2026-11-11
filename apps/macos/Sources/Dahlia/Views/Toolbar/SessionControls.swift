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
            .font(.dahliaTitle3)
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
    let onPresentConfirmation: () -> Void

    private var isGeneratingCurrentMeeting: Bool {
        viewModel.isSummaryGenerating
    }

    private var isGenerateSummaryEnabled: Bool {
        sidebarViewModel.canEditCurrentWorkspace && !isGeneratingCurrentMeeting && viewModel.canGenerateSummary
    }

    var body: some View {
        Button(action: onPresentConfirmation) {
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
            .font(.dahliaTitle3)
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
    @Environment(CodexChatCoordinator.self) private var chatCoordinator
    @ObservedObject var viewModel: CaptionViewModel
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
                        .font(.system(size: DahliaTypography.size(offset: 10), weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.dahliaHeadline)
                        .lineLimit(1)
                    Text(L10n.summary)
                        .font(.dahliaBody)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()
                .padding(.horizontal, 20)

            VStack(spacing: 2) {
                SummarySharePopoverRow(title: L10n.copySummaryForGoogleDocs, systemImage: "doc.richtext") {
                    copySummary(for: .googleDocs)
                }
                SummarySharePopoverRow(title: L10n.copySummaryForSlack, systemImage: "message") {
                    copySummary(for: .slack)
                }
                SummarySharePopoverRow(title: L10n.exportToGoogleDrive, systemImage: "doc.badge.arrow.up") {
                    exportToGoogleDrive()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .padding(.vertical, 8)
    }

    private func copySummary(for destination: SummaryShareRenderer.Destination) {
        viewModel.copyCurrentSummary(for: destination)
        dismiss()
    }

    /// Dahlia AI writes the document through the account's Google Drive MCP.
    private func exportToGoogleDrive() {
        chatCoordinator.sendInNewDockedChat(L10n.exportToGoogleDrivePrompt)
        dismiss()
    }
}

private struct SummarySharePopoverRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: DahliaTypography.size(offset: 4)))
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(width: 22)
                Text(title)
                    .font(.dahliaBody)
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
        .onHover { isHovering = $0 }
    }
}
