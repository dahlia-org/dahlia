import SwiftUI

struct MeetingListSidebarView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var updateController: AppUpdateController
    var sidebarViewModel: SidebarViewModel
    @Bindable var mainWindowNavigation: MainWindowNavigation
    let recordingCoordinator: RecordingCoordinator
    let isShowingUpcomingSchedule: Bool
    let onShowUpcomingSchedule: () -> Void
    let isShowingUnprocessedRecordings: Bool
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void
    let onCreateProject: () -> Void
    let onOpenProject: (UUID, ProjectNavigationIntent) -> Void
    let onSelectVault: (VaultRecord) -> Void

    @State private var renderedMeetingSelection: Set<UUID> = []
    @State private var editingMeetingId: UUID?
    @State private var editingMeetingName = ""
    @State private var pendingDeletion: MeetingDeletionRequest?
    @State private var collapsedProjectKeys: Set<MeetingProjectKey> = []
    @State private var collapsedDateGroupIDs: Set<String> = []
    @State private var isPinnedSectionExpanded = true
    @State private var isMainSectionExpanded = true
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
                isShowingUnprocessedRecordings: isShowingUnprocessedRecordings,
                unprocessedRecordingCount: sidebarViewModel.unprocessedRecordingItems.count,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings,
                showsCustomerIntelligence: showsCustomerIntelligence,
                onOpenCustomerIntelligence: onOpenCustomerIntelligence
            )
            List(selection: meetingSelection) {
                if !pinnedProjectGroups.isEmpty {
                    MeetingSidebarListGroupLabel(
                        title: L10n.pinned,
                        isExpanded: isPinnedSectionExpanded,
                        onToggleExpansion: { isPinnedSectionExpanded.toggle() }
                    )
                    if isPinnedSectionExpanded {
                        ForEach(pinnedProjectGroups) { group in
                            projectSection(group, isPinned: true)
                        }
                    }
                }

                MeetingSidebarHeader(
                    displayMode: $mainWindowNavigation.meetingSidebarDisplayMode,
                    isExpanded: isMainSectionExpanded,
                    canCreateProject: sidebarViewModel.currentVault != nil,
                    onToggleExpansion: { isMainSectionExpanded.toggle() },
                    onCreateProject: onCreateProject
                )
                .listRowSeparator(.hidden)

                if isMainSectionExpanded {
                    if let selectedMeeting = selectedMeetingOutsideVisibleItems {
                        Section {
                            meetingRow(selectedMeeting)
                        } header: {
                            Text(sidebarViewModel.isSearchingMeetings ? L10n.selectedMeetingOutsideResults : L10n.selectedMeeting)
                                .font(DahliaDesign.sidebarFont)
                        }
                    }

                    if mainWindowNavigation.meetingSidebarDisplayMode == .chronological {
                        ForEach(sidebarViewModel.displayedMeetingGroups) { group in
                            MeetingSidebarListGroupLabel(
                                title: group.title,
                                isExpanded: !collapsedDateGroupIDs.contains(group.id),
                                onToggleExpansion: { collapsedDateGroupIDs.toggle(group.id) }
                            )
                            if !collapsedDateGroupIDs.contains(group.id) {
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
                    } else {
                        ForEach(unpinnedProjectGroups) { group in
                            projectSection(group, isPinned: false)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.trailing, 12, for: .scrollContent)
            .tint(DahliaDesign.sidebarSelectionColor)
            .scrollContentBackground(.hidden)
            .overlay {
                if !isMainSectionExpanded {
                    EmptyView()
                } else if mainWindowNavigation.meetingSidebarDisplayMode == .chronological {
                    MeetingListStatusOverlay(
                        isLoaded: sidebarViewModel.isDisplayedMeetingListLoaded,
                        error: sidebarViewModel.displayedMeetingListLoadError,
                        isEmpty: sidebarViewModel.displayedMeetingItems.isEmpty
                            && pinnedProjectGroups.isEmpty,
                        isSearching: sidebarViewModel.isSearchingMeetings,
                        onRetry: sidebarViewModel.retryDisplayedMeetingLoading,
                        onClearSearch: clearSearch
                    )
                } else {
                    MeetingProjectListStatusOverlay(
                        isLoaded: sidebarViewModel.isProjectMeetingProjectionLoaded
                            && sidebarViewModel.isProjectCatalogLoaded,
                        error: sidebarViewModel.projectMeetingProjectionLoadError
                            ?? (sidebarViewModel.projectCatalogLoadFailed
                                ? L10n.projectCatalogLoadFailedDescription
                                : nil),
                        isEmpty: sidebarViewModel.projectMeetingGroups.isEmpty,
                        onRetry: {
                            sidebarViewModel.retryProjectCatalogLoading()
                            sidebarViewModel.retryProjectMeetingProjection()
                        }
                    )
                }
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
        .font(DahliaDesign.sidebarFont)
        .onDeleteCommand {
            requestDeletion(of: sidebarViewModel.selectedMeetingIds)
        }
        .onAppear {
            renderedMeetingSelection = sidebarViewModel.selectedMeetingIds
            sidebarViewModel.setProjectMeetingProjectionNeeded(needsProjectMeetingProjection)
        }
        .onDisappear {
            sidebarViewModel.setProjectMeetingProjectionNeeded(false)
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { _, selection in
            renderedMeetingSelection = selection
        }
        .onChange(of: mainWindowNavigation.meetingSidebarDisplayMode) {
            sidebarViewModel.cancelProjectMeetingPageLoads()
        }
        .onChange(of: needsProjectMeetingProjection) { _, isNeeded in
            sidebarViewModel.setProjectMeetingProjectionNeeded(isNeeded)
        }
        .meetingDeletionConfirmation(request: $pendingDeletion) { meetingIds in
            sidebarViewModel.deleteMeetings(ids: meetingIds)
        }
    }

    private var needsProjectMeetingProjection: Bool {
        mainWindowNavigation.meetingSidebarDisplayMode == .byProject
            || !mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id).isEmpty
    }

    private var pinnedProjectGroups: [MeetingProjectGroup] {
        let groups = Dictionary(uniqueKeysWithValues: sidebarViewModel.projectMeetingGroups.compactMap { group in
            group.project.map { ($0.projectId, group) }
        })
        let pinnedGroups = mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id).compactMap { groups[$0] }
        guard mainWindowNavigation.meetingSidebarDisplayMode == .chronological else { return pinnedGroups }
        return Self.limitMeetingCount(
            in: pinnedGroups,
            to: max(SidebarViewModel.maximumVisibleMeetings - sidebarViewModel.displayedMeetingItems.count, 0)
        )
    }

    static func limitMeetingCount(
        in groups: [MeetingProjectGroup],
        to maximumCount: Int
    ) -> [MeetingProjectGroup] {
        var remainingCount = max(maximumCount, 0)
        return groups.map { group in
            let meetings = Array(group.meetings.prefix(remainingCount))
            remainingCount -= meetings.count
            guard meetings.count < group.meetings.count else { return group }
            return MeetingProjectGroup(
                key: group.key,
                project: group.project,
                meetings: meetings,
                hasMore: false,
                isLoadingMore: group.isLoadingMore,
                loadError: group.loadError,
                isLimited: true
            )
        }
    }

    private var unpinnedProjectGroups: [MeetingProjectGroup] {
        let pinnedIDs = Set(mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id))
        return sidebarViewModel.projectMeetingGroups.filter { group in
            group.project.map { !pinnedIDs.contains($0.projectId) } ?? true
        }
    }

    private var meetingListLimitMessage: String? {
        guard sidebarViewModel.isDisplayedMeetingListLimited else { return nil }
        return sidebarViewModel.isSearchingMeetings
            ? L10n.refineMeetingSearch
            : L10n.searchForOlderMeetings
    }

    private var selectedMeetingOutsideVisibleItems: MeetingSidebarItem? {
        guard let item = sidebarViewModel.selectedMeetingOutsideDisplayedItems else { return nil }
        if mainWindowNavigation.meetingSidebarDisplayMode == .byProject,
           sidebarViewModel.projectMeetingGroups.contains(where: { group in
               group.meetings.contains(where: { $0.meetingId == item.meetingId })
           }) {
            return nil
        }
        return item
    }

    private func meetingRow(_ item: MeetingSidebarItem) -> some View {
        MeetingSidebarRow(
            item: item,
            showsDateInTimestamp: mainWindowNavigation.meetingSidebarDisplayMode == .byProject,
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

    private func projectSection(_ group: MeetingProjectGroup, isPinned: Bool) -> some View {
        MeetingSidebarProjectSection(
            group: group,
            projectAppearance: group.project.map {
                mainWindowNavigation.projectAppearance(
                    projectId: $0.projectId,
                    vaultId: sidebarViewModel.currentVault?.id
                )
            } ?? .default,
            isPinned: isPinned,
            isExpanded: !collapsedProjectKeys.contains(group.key),
            selectedProjectID: mainWindowNavigation.section == .projects
                ? mainWindowNavigation.selectedProjectId
                : nil,
            canCreateMeeting: !viewModel.isRecordingStartPending && !viewModel.isFinalizingRecording,
            showsMeetingDate: mainWindowNavigation.meetingSidebarDisplayMode == .byProject,
            selectedMeetingIDs: renderedMeetingSelection,
            activeRecordingID: viewModel.recordingMeetingId,
            editingMeetingId: editingMeetingId,
            editingMeetingName: $editingMeetingName,
            isRenameFieldFocused: $isRenameFieldFocused,
            onCommitRename: commitRename,
            onCancelRename: cancelRename,
            onToggleExpansion: { collapsedProjectKeys.toggle(group.key) },
            allowsListSelection: !isPinned
                || mainWindowNavigation.meetingSidebarDisplayMode == .byProject,
            onSelectMeeting: sidebarViewModel.selectMeeting,
            onOpenProject: onOpenProject,
            onTogglePin: { mainWindowNavigation.toggleProjectPin($0, vaultId: sidebarViewModel.currentVault?.id) },
            onCreateMeeting: recordingCoordinator.createDraftMeeting,
            onLoadMore: sidebarViewModel.loadMoreProjectMeetings
        )
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
