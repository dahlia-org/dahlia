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

struct LiveSubtitleOverlayToolbarButton: View {
    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false

    var body: some View {
        Button {
            liveSubtitleOverlayEnabled.toggle()
        } label: {
            Label(
                liveSubtitleOverlayEnabled ? L10n.hideLiveSubtitles : L10n.showLiveSubtitles,
                systemImage: liveSubtitleOverlayEnabled ? "text.bubble.fill" : "text.bubble"
            )
        }
        .help(liveSubtitleOverlayEnabled ? L10n.hideLiveSubtitles : L10n.showLiveSubtitles)
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
