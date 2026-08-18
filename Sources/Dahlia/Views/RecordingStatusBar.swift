import AppKit
import SwiftUI

struct RecordingStatusBar: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false
    @State private var retainedRecordingMeetingItem: MeetingSidebarItem?

    private var recordingMeetingId: UUID? { viewModel.recordingMeetingId }

    private var currentRecordingMeetingItem: MeetingSidebarItem? {
        guard let recordingMeetingId else { return nil }
        return sidebarViewModel.meetingSidebarItem(id: recordingMeetingId)
    }

    private var recordingMeetingItem: MeetingSidebarItem? {
        currentRecordingMeetingItem
            ?? retainedRecordingMeetingItem.flatMap { $0.meetingId == recordingMeetingId ? $0 : nil }
    }

    private var recordingTitle: String {
        let title = recordingMeetingItem?.meetingName ?? ""
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }

    private var activeRecordingSession: RecordingSessionTimeline? {
        let sessions = viewModel.activeTranscriptStore.recordingSessions
        return sessions.last(where: { $0.endedAt == nil }) ?? sessions.last
    }

    private var recordingTimelineStart: Date {
        activeRecordingSession?.startedAt
            ?? viewModel.activeTranscriptStore.recordingStartTime
            ?? recordingMeetingItem?.effectiveRecordingStartedAt
            ?? Date.now
    }

    private var transcriptionMode: TranscriptionMode {
        viewModel.activeTranscriptionMode ?? .defaultMode
    }

    private var recordingLabels: (activity: String, returnToMeeting: String, stop: String) {
        switch transcriptionMode {
        case .realtime:
            (L10n.transcribingNow, L10n.returnToTranscribingMeeting, L10n.stopTranscribing)
        case .batch:
            (L10n.recordingNow, L10n.returnToRecordingMeeting, L10n.stopRecording)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: returnToRecordingMeeting) {
                    panelContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(recordingMeetingId == nil)
                .help(recordingLabels.returnToMeeting)
                .accessibilityLabel("\(recordingLabels.activity), \(recordingTitle)")

                Button(recordingLabels.stop, systemImage: "stop.fill", action: recordingCoordinator.stopRecording)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help(recordingLabels.stop)
            }

            Divider()

            VStack(spacing: 6) {
                microphoneMenu
                systemAudioMenu
                languageMenu
                RecordingLiveSubtitleToggle(isEnabled: $liveSubtitleOverlayEnabled)
                screenSourceMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
        .onAppear(perform: retainCurrentRecordingMeetingItem)
        .onChange(of: currentRecordingMeetingItem) {
            retainCurrentRecordingMeetingItem()
        }
        .onChange(of: recordingMeetingId) {
            guard recordingMeetingId != nil else {
                retainedRecordingMeetingItem = nil
                return
            }
            retainCurrentRecordingMeetingItem()
        }
    }

    private var panelContent: some View {
        HStack(spacing: 8) {
            RecordingActivityIcon(mode: transcriptionMode)

            VStack(alignment: .leading, spacing: 2) {
                Text(recordingLabels.activity)
                    .dahliaFont(.metadata, weight: .bold)
                    .foregroundStyle(.red)

                Text(recordingTitle)
                    .dahliaFont(.metadata)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            elapsedText
                .fixedSize()
        }
    }

    private var elapsedText: some View {
        TimelineView(.periodic(from: recordingTimelineStart, by: 1)) { context in
            Text(formatElapsedTime(at: context.date))
                .dahliaFont(.metadata, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var microphoneMenu: some View {
        RecordingSourceMenu(
            title: L10n.mic,
            displayValue: selectedMicrophoneDisplayName,
            systemImage: "mic.fill",
            audioLevelStore: viewModel.recordingAudioLevelStore,
            inputSource: .microphone,
            isInputActive: viewModel.isRecordingAudioSourceActive(.microphone),
            selection: $viewModel.microphoneSelection,
            items: microphoneMenuItems
        ) { oldValue, newValue in
            viewModel.handleMicrophoneSelectionChange(from: oldValue, to: newValue)
        }
        .help(L10n.microphone)
        .task {
            await viewModel.refreshAvailableMicrophones()
        }
    }

    private var microphoneMenuItems: [RecordingSourceMenuItem<MicrophoneSelection>] {
        var items: [RecordingSourceMenuItem<MicrophoneSelection>] = [
            .option(title: L10n.none, value: .none),
            .divider,
            .option(title: viewModel.systemDefaultMicrophoneTitle, value: .systemDefault),
        ]

        if !viewModel.availableMicrophones.isEmpty {
            items.append(.divider)
            items.append(contentsOf: viewModel.availableMicrophones.map { microphone in
                .option(title: microphone.name, value: .device(microphone.id))
            })
        }

        return items
    }

    private var systemAudioMenu: some View {
        RecordingSourceMenu(
            title: L10n.system,
            displayValue: viewModel.isSystemAudioEnabled ? L10n.record : L10n.none,
            systemImage: "speaker.wave.2.fill",
            audioLevelStore: viewModel.recordingAudioLevelStore,
            inputSource: .system,
            isInputActive: viewModel.isRecordingAudioSourceActive(.system),
            selection: $viewModel.isSystemAudioEnabled,
            items: [
                .option(title: L10n.noComputerAudio, value: false),
                .option(title: L10n.recordComputerAudio, value: true),
            ]
        ) { oldValue, newValue in
            viewModel.handleSystemAudioSelectionChange(from: oldValue, to: newValue)
        }
        .help(L10n.systemAudio)
    }

    private var languageMenu: some View {
        RecordingSourceMenu(
            title: L10n.language,
            displayValue: selectedLanguageDisplayName,
            systemImage: "globe",
            selection: $viewModel.selectedLocale,
            items: languageMenuItems
        )
        .help(L10n.language)
    }

    private var languageMenuItems: [RecordingSourceMenuItem<String>] {
        if viewModel.filteredLocales.isEmpty {
            return [.option(title: selectedLanguageDisplayName, value: viewModel.selectedLocale)]
        }

        return viewModel.filteredLocales.map { locale in
            let id = locale.identifier
            return .option(title: locale.localizedString(forIdentifier: id) ?? id, value: id)
        }
    }

    private var screenSourceMenu: some View {
        RecordingSourceMenu(
            title: L10n.screen,
            displayValue: selectedScreenSourceDisplayName,
            systemImage: "rectangle.on.rectangle",
            selection: $viewModel.screenshotCaptureSource,
            items: screenSourceMenuItems
        )
        .help(L10n.source)
        .onAppear {
            viewModel.refreshAvailableWindows()
        }
        .onHover { hovering in
            if hovering {
                viewModel.refreshAvailableWindows()
            }
        }
    }

    private var screenSourceMenuItems: [RecordingSourceMenuItem<ScreenshotCaptureSource>] {
        var items: [RecordingSourceMenuItem<ScreenshotCaptureSource>] = [
            .option(title: L10n.notSelected, value: .none),
            .divider,
            .option(title: L10n.entireDesktop, value: .entireDesktop),
            .divider,
        ]
        items.append(contentsOf: viewModel.availableWindows.map { window in
            .option(title: window.displayName, value: .window(window.id))
        })
        return items
    }

    private var selectedMicrophoneDisplayName: String {
        switch viewModel.microphoneSelection {
        case .none:
            L10n.none
        case .systemDefault:
            viewModel.systemDefaultMicrophoneTitle
        case let .device(id):
            viewModel.availableMicrophones.first(where: { $0.id == id })?.name ?? viewModel.systemDefaultMicrophoneTitle
        }
    }

    private var selectedLanguageDisplayName: String {
        let id = viewModel.selectedLocale
        if let locale = viewModel.filteredLocales.first(where: { $0.identifier == id }) {
            return locale.localizedString(forIdentifier: id) ?? id
        }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    private var selectedScreenSourceDisplayName: String {
        switch viewModel.screenshotCaptureSource {
        case .none:
            L10n.notSelected
        case .entireDesktop:
            L10n.entireDesktop
        case let .window(windowID):
            viewModel.availableWindows.first(where: { $0.id == windowID })?.displayName ?? L10n.notSelected
        }
    }

    private func returnToRecordingMeeting() {
        guard let recordingMeetingId else { return }
        sidebarViewModel.selectMeeting(recordingMeetingId)
        viewModel.returnToRecordingMeeting()
    }

    private func retainCurrentRecordingMeetingItem() {
        if let currentRecordingMeetingItem {
            retainedRecordingMeetingItem = currentRecordingMeetingItem
        } else if retainedRecordingMeetingItem?.meetingId != recordingMeetingId {
            retainedRecordingMeetingItem = nil
        }
    }

    private func formatElapsedTime(at date: Date) -> String {
        let elapsedSeconds = if let activeRecordingSession {
            activeRecordingSession.offsetSeconds + date.timeIntervalSince(activeRecordingSession.startedAt)
        } else {
            date.timeIntervalSince(recordingTimelineStart)
        }
        let totalSeconds = max(0, Int(elapsedSeconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private enum RecordingSourceMenuItem<Value: Hashable> {
    case option(title: String, value: Value)
    case divider
}

private struct RecordingSourceMenu<Value: Hashable>: View {
    let title: String
    let displayValue: String
    let systemImage: String
    var audioLevelStore: RecordingAudioLevelStore?
    var inputSource: RecordingAudioSource?
    var isInputActive = false
    @Binding var selection: Value
    let items: [RecordingSourceMenuItem<Value>]
    var onSelectionChange: (Value, Value) -> Void = { _, _ in }

    var body: some View {
        RecordingSourceControlLabel(
            title: title,
            value: displayValue,
            systemImage: systemImage,
            audioLevelStore: audioLevelStore,
            inputSource: inputSource,
            isInputActive: isInputActive
        )
        .overlay {
            RecordingSourcePopupButton(
                selection: $selection,
                items: items,
                onSelectionChange: onSelectionChange
            )
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(title), \(displayValue)")
    }
}

private struct RecordingSourcePopupButton<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let items: [RecordingSourceMenuItem<Value>]
    let onSelectionChange: (Value, Value) -> Void

    private var options: [(title: String, value: Value)] {
        items.compactMap { item in
            if case let .option(title, value) = item {
                return (title, value)
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.alphaValue = 0.01
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.removeAllItems()

        var optionIndex = 0
        for item in items {
            switch item {
            case let .option(title, _):
                // addItem(withTitle:) は同名の既存項目を除去してしまうため、
                // 同名ウィンドウ・同名マイクが共存できるよう NSMenuItem を直接追加する。
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.tag = optionIndex
                button.menu?.addItem(menuItem)
                optionIndex += 1
            case .divider:
                button.menu?.addItem(.separator())
            }
        }

        if let selectedIndex = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(withTag: selectedIndex)
        }
    }

    final class Coordinator: NSObject {
        var parent: RecordingSourcePopupButton

        init(parent: RecordingSourcePopupButton) {
            self.parent = parent
        }

        @MainActor @objc func selectionDidChange(_ sender: NSPopUpButton) {
            guard let selectedItem = sender.selectedItem,
                  selectedItem.tag >= 0,
                  selectedItem.tag < parent.options.count else { return }

            let newValue = parent.options[selectedItem.tag].value
            let oldValue = parent.selection
            guard oldValue != newValue else { return }
            parent.selection = newValue
            parent.onSelectionChange(oldValue, newValue)
        }
    }
}

private struct RecordingSourceControlLabel: View {
    let title: String
    let value: String
    let systemImage: String
    let audioLevelStore: RecordingAudioLevelStore?
    let inputSource: RecordingAudioSource?
    let isInputActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(title)
                .dahliaFont(.metadata, weight: .semibold)
                .foregroundStyle(.primary)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .dahliaFont(.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let audioLevelStore, let inputSource {
                RecordingInputLevelMeter(
                    store: audioLevelStore,
                    source: inputSource,
                    isActive: isInputActive
                )
            }

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecordingInputLevelMeter: View {
    private static let segmentHeights: [CGFloat] = [4, 6, 8, 10, 12]

    @ObservedObject var store: RecordingAudioLevelStore
    let source: RecordingAudioSource
    let isActive: Bool

    private var level: Double {
        store.level(for: source)
    }

    private var activeSegmentCount: Int {
        guard isActive, level > 0 else { return 0 }
        return min(Self.segmentHeights.count, max(1, Int(ceil(level * Double(Self.segmentHeights.count)))))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Self.segmentHeights.enumerated(), id: \.offset) { index, height in
                Capsule()
                    .fill(index < activeSegmentCount ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: height)
            }
        }
        .frame(width: 23, height: 12, alignment: .bottom)
        .opacity(isActive ? 1 : 0.45)
        .animation(.linear(duration: 0.12), value: activeSegmentCount)
        .accessibilityLabel(L10n.inputLevel)
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}
