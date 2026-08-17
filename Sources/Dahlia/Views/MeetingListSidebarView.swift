import SwiftUI

struct MeetingListSidebarView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var updateController: AppUpdateController
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    let isShowingUpcomingSchedule: Bool
    let onShowUpcomingSchedule: () -> Void
    let onOpenProjectManagement: () -> Void
    let isShowingUnprocessedRecordings: Bool
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void
    let onCreateProject: () -> Void
    let onSelectVault: (VaultRecord) -> Void

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
            MainSidebarNavigationView(
                onCreateMeeting: recordingCoordinator.createDraftMeeting,
                canCreateMeeting: !viewModel.isRecordingStartPending && !viewModel.isFinalizingRecording,
                canStartQuickRecording: recordingCoordinator.canStartNewMeeting,
                onStartQuickRecording: recordingCoordinator.startQuickRecording,
                isShowingUpcomingSchedule: isShowingUpcomingSchedule,
                onShowUpcomingSchedule: onShowUpcomingSchedule,
                isShowingProjectManagement: false,
                onShowProjectManagement: onOpenProjectManagement,
                canCreateProject: sidebarViewModel.currentVault != nil,
                onCreateProject: onCreateProject,
                isShowingUnprocessedRecordings: isShowingUnprocessedRecordings,
                unprocessedRecordingCount: sidebarViewModel.unprocessedRecordingItems.count,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings,
                showsCustomerIntelligence: showsCustomerIntelligence,
                onOpenCustomerIntelligence: onOpenCustomerIntelligence
            )
            SidebarSectionHeader(title: L10n.meetings)

            List(selection: meetingSelection) {
                if let selectedMeeting = sidebarViewModel.selectedMeetingOutsideDisplayedItems {
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
            .tint(DahliaDesign.sidebarSelectionColor)
            .scrollContentBackground(.hidden)
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

            MainSidebarBottomArea(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator,
                updateController: updateController,
                onSelectVault: onSelectVault
            )
        }
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
        sidebarViewModel.updateMeetingSearchCriteria(MeetingSearchCriteria())
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
