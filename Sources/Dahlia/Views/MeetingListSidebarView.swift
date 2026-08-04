import Foundation
import SwiftUI

struct MeetingListSidebarView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var scopeProjectID: UUID?

    @State private var searchText = ""
    @State private var searchTokens: [MeetingSearchToken] = []
    @State private var renderedMeetingSelection: Set<UUID> = []
    @State private var editingMeetingId: UUID?
    @State private var editingMeetingName = ""
    @State private var pendingDeletion: MeetingDeletionRequest?
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

    var body: some View {
        VStack(spacing: 0) {
            List(selection: meetingSelection) {
                if let selectedMeeting = sidebarViewModel.selectedMeetingOutsideDisplayedItems,
                   MeetingSidebarSearchModifier.projectScopeIncludes(
                       meetingProjectID: selectedMeeting.projectId,
                       scopeProjectID: scopeProjectID
                   ) {
                    Section(sidebarViewModel.isSearchingMeetings ? L10n.selectedMeetingOutsideResults : L10n.selectedMeeting) {
                        meetingRow(selectedMeeting)
                    }
                }

                ForEach(sidebarViewModel.displayedMeetingGroups) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { item in
                            meetingRow(item)
                        }
                    }
                }

                MeetingListPaginationRow(
                    error: sidebarViewModel.displayedMeetingListLoadError,
                    hasItems: !sidebarViewModel.displayedMeetingItems.isEmpty,
                    isLoadingMore: sidebarViewModel.isDisplayedMeetingListLoadingMore,
                    hasMore: sidebarViewModel.hasMoreDisplayedMeetings,
                    limitMessage: meetingListLimitMessage,
                    loadTrigger: """
                    meeting-page-\(sidebarViewModel.meetingSearchCriteria.identity)\
                    -\(sidebarViewModel.displayedMeetingItems.count)
                    """,
                    onRetry: sidebarViewModel.retryDisplayedMeetingLoading,
                    onLoadMore: sidebarViewModel.loadMoreDisplayedMeetings
                )
            }
            .listStyle(.sidebar)
            .overlay {
                MeetingListStatusOverlay(
                    isLoaded: sidebarViewModel.isDisplayedMeetingListLoaded,
                    error: sidebarViewModel.displayedMeetingListLoadError,
                    isEmpty: sidebarViewModel.displayedMeetingItems.isEmpty,
                    isSearching: sidebarViewModel.isSearchingMeetings,
                    onRetry: sidebarViewModel.retryDisplayedMeetingLoading,
                    onClearSearch: clearSearch
                )
            }
            .contextMenu(forSelectionType: UUID.self) { selection in
                contextMenu(for: selection)
            }

            if recordingPlacement.showsSidebarIndicator {
                RecordingStatusBar(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator
                )
                .padding(8)
            }
        }
        .meetingSidebarSearch(
            text: $searchText,
            tokens: $searchTokens,
            sidebarViewModel: sidebarViewModel,
            scopeProjectID: scopeProjectID
        )
        .onDeleteCommand {
            requestDeletion(of: sidebarViewModel.selectedMeetingIds)
        }
        .onAppear {
            renderedMeetingSelection = sidebarViewModel.selectedMeetingIds
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { _, selection in
            renderedMeetingSelection = selection
        }
        .meetingDeletionConfirmation(request: $pendingDeletion) { meetingIds in
            sidebarViewModel.deleteMeetings(ids: meetingIds)
        }
    }

    private var recordingPlacement: RecordingCommandPlacement {
        RecordingCommandPlacement(
            isListening: viewModel.isListening,
            isSidebarVisible: true,
            recordingMeetingID: viewModel.recordingMeetingId,
            currentMeetingID: viewModel.currentMeetingId
        )
    }

    private var meetingListLimitMessage: String? {
        guard sidebarViewModel.isDisplayedMeetingListLimited else { return nil }
        return sidebarViewModel.isSearchingMeetings
            ? L10n.refineMeetingSearch
            : L10n.searchForOlderMeetings
    }

    private func meetingRow(_ item: MeetingSidebarItem) -> some View {
        MeetingSidebarRow(
            item: item,
            searchText: sidebarViewModel.meetingSearchCriteria.text,
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

    private func clearSearch() {
        searchText = ""
        searchTokens.removeAll()
        sidebarViewModel.updateMeetingSearchCriteria(MeetingSidebarSearchModifier.applyingProjectScope(
            scopeProjectID,
            to: MeetingSearchCriteria()
        ))
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
                requestDeletion(of: [meetingId])
            }
        } else if !selection.isEmpty {
            moveMenu(for: selection)

            Divider()

            Button(L10n.deleteCount(selection.count), role: .destructive) {
                requestDeletion(of: selection)
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
        guard let item = sidebarViewModel.meetingSidebarItem(id: meetingId) else { return }
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

    private func requestDeletion(of meetingIds: Set<UUID>) {
        guard !meetingIds.isEmpty else { return }
        let meetingName = meetingIds.count == 1
            ? meetingIds.first
            .flatMap { sidebarViewModel.meetingSidebarItem(id: $0)?.meetingName.nilIfBlank }
            : nil
        pendingDeletion = MeetingDeletionRequest(
            meetingIds: meetingIds,
            meetingName: meetingName
        )
    }
}

private struct RecordingStatusBar: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

    @State private var retainedRecordingMeetingItem: MeetingSidebarItem?

    private var recordingMeetingId: UUID? {
        viewModel.recordingMeetingId
    }

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
            ?? recordingMeetingItem?.createdAt
            ?? Date()
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

            Button(recordingLabels.stop, systemImage: "stop.fill") {
                recordingCoordinator.stopRecording()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .help(recordingLabels.stop)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.red.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
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
                    .font(.caption.bold())
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

private struct MeetingSidebarRow: View {
    let item: MeetingSidebarItem
    let searchText: String
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
                    highlightedText(displayTitle)
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

                if let matchContext = visibleMatchContext {
                    searchMatchRow(matchContext)
                }
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
            Image(systemName: item.calendarEventTitle == nil ? "waveform" : "calendar")
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

    private var visibleMatchContext: MeetingSearchMatchContext? {
        guard !searchText.isEmpty,
              let context = item.searchMatchContext,
              context.kind != .title,
              context.kind != .project else { return nil }
        return context
    }

    private func searchMatchRow(_ context: MeetingSearchMatchContext) -> some View {
        HStack(spacing: 5) {
            if context.kind == .tag {
                Circle()
                    .fill(context.colorHex.map(Color.init(hex:)) ?? Color.secondary)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: context.kind == .calendar ? "calendar" : "text.alignleft")
                    .frame(width: 8)
            }

            Text(matchContextPrefix(context.kind))
                .foregroundStyle(.tertiary)
            highlightedText(context.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func matchContextPrefix(_ kind: MeetingSearchMatchContext.Kind) -> String {
        switch kind {
        case .description:
            L10n.descriptionMatch
        case .calendar:
            L10n.calendarMatch
        case .tag:
            L10n.tagMatch
        case .project:
            L10n.projectMatch
        case .title:
            ""
        }
    }

    private func highlightedText(_ text: String) -> Text {
        guard !searchText.isEmpty,
              let range = text.range(
                  of: searchText,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  locale: .current
              ) else {
            return Text(text)
        }
        let prefix = Text(verbatim: String(text[..<range.lowerBound]))
        let match = Text(verbatim: String(text[range])).bold().foregroundStyle(Color.accentColor)
        let suffix = Text(verbatim: String(text[range.upperBound...]))
        return Text("\(prefix)\(match)\(suffix)")
    }

    private var accessibilityLabel: String {
        var components = [displayTitle]
        if isActiveRecording {
            components.append(L10n.recordingNow)
        }
        if let calendarEventTitle = item.calendarEventTitle {
            components.append(L10n.calendarEventOrigin(calendarEventTitle.nilIfBlank ?? L10n.newMeeting))
        }
        if !searchText.isEmpty,
           let matchContext = item.searchMatchContext,
           matchContext.kind != .title {
            components.append("\(matchContextPrefix(matchContext.kind)) \(matchContext.text)")
        }
        return components.joined(separator: ", ")
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
