import SwiftUI

struct RecordToolbarButton: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    private var isEnabled: Bool {
        viewModel.isListening || recordingCoordinator.canStartNewMeeting
    }

    var body: some View {
        Button(action: toggle) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
        }
        .disabled(!isEnabled)
        .keyboardShortcut(.space, modifiers: [])
        .help(label)
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
        viewModel.isListening ? "stop.fill" : "record.circle"
    }

    private var label: String {
        viewModel.isListening ? L10n.stopRecording : L10n.startRecording
    }

    private var iconColor: Color {
        if viewModel.isListening {
            return .secondary
        }
        return isEnabled ? .red : .secondary
    }
}

struct GenerateSummaryToolbarButton: View {
    @ObservedObject var viewModel: CaptionViewModel

    private var isGeneratingCurrentMeeting: Bool {
        viewModel.summaryGeneratingMeetingId == viewModel.currentMeetingId
    }

    var body: some View {
        Button {
            viewModel.triggerManualSummary()
        } label: {
            Label {
                Text(L10n.generateSummary)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(summaryIconColor)
            }
        }
        .disabled(isGeneratingCurrentMeeting || !viewModel.canGenerateSummary)
        .help(L10n.generateSummary)
    }

    private var summaryIconColor: Color {
        isGeneratingCurrentMeeting || !viewModel.canGenerateSummary ? .secondary : Color.accentColor
    }
}

struct SummaryToolbarControlGroup: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    var body: some View {
        ControlGroup {
            ShareSummaryToolbarButton(viewModel: viewModel)
            GenerateSummaryToolbarButton(viewModel: viewModel)
            RecordToolbarButton(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator
            )
        }
        .labelStyle(.iconOnly)
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
    @ObservedObject var viewModel: CaptionViewModel
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

            SummarySharePopoverRow(title: L10n.copySummary, systemImage: "doc.on.doc") {
                viewModel.copyCurrentSummaryForSlack()
                dismiss()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .padding(.vertical, 8)
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
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
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
        .onHover { isHovering = $0 }
    }
}
