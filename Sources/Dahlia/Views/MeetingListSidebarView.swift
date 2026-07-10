import AppKit
import CoreGraphics
import SwiftUI

struct MeetingListSidebarView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    @State private var searchText = ""
    @State private var renderedMeetingSelection: Set<UUID> = []
    @State private var editingMeetingId: UUID?
    @State private var editingMeetingName = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var meetingSelection: Binding<Set<UUID>> {
        Binding(
            get: { renderedMeetingSelection },
            set: { selection in
                renderedMeetingSelection = selection
                sidebarViewModel.selectedMeetingIds = selection
            }
        )
    }

    private var filteredMeetings: [MeetingOverviewItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return sidebarViewModel.allMeetings }

        return sidebarViewModel.allMeetings.filter { item in
            item.meetingName.localizedLowercase.contains(query)
                || (item.projectName?.localizedLowercase.contains(query) ?? false)
                || (item.latestSegmentText?.localizedLowercase.contains(query) ?? false)
                || item.tags.contains { $0.name.localizedLowercase.contains(query) }
        }
    }

    private var groups: [MeetingDateGroup] {
        MeetingDateGrouping.groups(from: filteredMeetings)
    }

    var body: some View {
        List(selection: meetingSelection) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.meetings) { item in
                        MeetingSidebarRow(
                            item: item,
                            isSelected: renderedMeetingSelection.contains(item.meetingId),
                            isActiveRecording: item.meetingId == viewModel.recordingMeetingId,
                            isEditing: editingMeetingId == item.meetingId,
                            editingName: $editingMeetingName,
                            isFocused: $isRenameFieldFocused,
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename
                        )
                        .tag(item.meetingId)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottom) {
            if viewModel.isListening {
                RecordingStatusBar(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: L10n.searchMeetings)
        .contextMenu(forSelectionType: UUID.self) { selection in
            contextMenu(for: selection)
        }
        .onDeleteCommand {
            sidebarViewModel.deleteMeetings(ids: sidebarViewModel.selectedMeetingIds)
        }
        .onAppear {
            renderedMeetingSelection = sidebarViewModel.selectedMeetingIds
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { _, selection in
            renderedMeetingSelection = selection
        }
    }

    @ViewBuilder
    private func contextMenu(for selection: Set<UUID>) -> some View {
        if selection.count == 1, let meetingId = selection.first {
            Button(L10n.rename) {
                beginRename(meetingId)
            }

            moveMenu(for: [meetingId])

            Divider()

            Button(L10n.delete, role: .destructive) {
                sidebarViewModel.deleteMeeting(id: meetingId)
            }
        } else if !selection.isEmpty {
            moveMenu(for: selection)

            Divider()

            Button(L10n.deleteCount(selection.count), role: .destructive) {
                sidebarViewModel.deleteMeetings(ids: selection)
            }
        }
    }

    private func moveMenu(for meetingIds: Set<UUID>) -> some View {
        Menu(L10n.moveToProject) {
            Button(L10n.noProject) {
                sidebarViewModel.moveMeetings(ids: meetingIds, toProjectId: nil)
            }

            Divider()

            ForEach(sidebarViewModel.allProjectItems) { project in
                Button(project.projectName) {
                    sidebarViewModel.moveMeetings(ids: meetingIds, toProjectId: project.projectId)
                }
            }
        }
    }

    private func beginRename(_ meetingId: UUID) {
        guard let item = sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId }) else { return }
        editingMeetingId = meetingId
        editingMeetingName = item.meetingName
        isRenameFieldFocused = true
    }

    private func commitRename() {
        guard let editingMeetingId else { return }
        let trimmed = editingMeetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        sidebarViewModel.renameMeeting(id: editingMeetingId, newName: trimmed)
        cancelRename()
    }

    private func cancelRename() {
        editingMeetingId = nil
        editingMeetingName = ""
        isRenameFieldFocused = false
    }
}

private struct RecordingStatusBar: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false

    private var recordingMeetingId: UUID? {
        viewModel.recordingMeetingId
    }

    private var recordingMeetingItem: MeetingOverviewItem? {
        guard let recordingMeetingId else { return nil }
        return sidebarViewModel.allMeetings.first { $0.meetingId == recordingMeetingId }
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
            ?? recordingMeetingItem?.createdAt
            ?? Date()
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
                .help(L10n.returnToTranscribingMeeting)
                .accessibilityLabel("\(L10n.transcribingNow), \(recordingTitle)")

                Button {
                    recordingCoordinator.stopRecording()
                } label: {
                    Label(L10n.stopTranscribing, systemImage: "stop.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.stopTranscribing)
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
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private var panelContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.transcribingNow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)

                Text(recordingTitle)
                    .font(.caption)
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
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var microphoneMenu: some View {
        RecordingSourceMenu(
            title: L10n.mic,
            displayValue: selectedMicrophoneDisplayName,
            systemImage: "mic.fill",
            selection: $viewModel.microphoneSelection,
            items: microphoneMenuItems
        ) { oldValue, newValue in
            viewModel.handleMicrophoneSelectionChange(from: oldValue, to: newValue)
        }
        .help(L10n.microphone)
        .onAppear {
            viewModel.refreshAvailableMicrophones()
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
    @Binding var selection: Value
    let items: [RecordingSourceMenuItem<Value>]
    var onSelectionChange: (Value, Value) -> Void = { _, _ in }

    var body: some View {
        RecordingSourceControlLabel(
            title: title,
            value: displayValue,
            systemImage: systemImage
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

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

private struct MeetingSidebarRow: View {
    let item: MeetingOverviewItem
    let isSelected: Bool
    let isActiveRecording: Bool
    let isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField(L10n.title, text: $editingName)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)
                } else {
                    Text(displayTitle)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(startTimeText)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)

                    Text(durationText)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)

                    if let projectName {
                        ProjectPill(name: projectName, isSelected: isSelected)
                            .layoutPriority(-1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isActiveRecording {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(L10n.recordingNow)
        } else {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
        }
    }

    private var displayTitle: String {
        let trimmed = item.meetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }

    private var projectName: String? {
        guard let projectName = item.projectName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectName.isEmpty else { return nil }
        return projectName
    }

    private var startTimeText: String {
        Self.timeFormatter.string(from: item.createdAt)
    }

    private var durationText: String {
        guard let duration = item.duration else { return "00:00" }
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var accessibilityLabel: String {
        if isActiveRecording {
            return "\(displayTitle), \(L10n.recordingNow)"
        }
        return displayTitle
    }
}

private struct ProjectPill: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: 0.5)
            }
            .accessibilityLabel(name)
    }

    private var foregroundColor: Color {
        isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var backgroundColor: Color {
        isSelected ? Color(nsColor: .controlBackgroundColor).opacity(0.95) : Color(nsColor: .secondaryLabelColor).opacity(0.10)
    }

    private var borderColor: Color {
        isSelected ? Color(nsColor: .controlAccentColor).opacity(0.24) : Color(nsColor: .secondaryLabelColor).opacity(0.16)
    }
}
