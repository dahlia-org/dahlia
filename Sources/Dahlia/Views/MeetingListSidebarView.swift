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
    @State private var isProjectSectionExpanded = true
    @State private var isRecentSectionExpanded = true
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
                    isExpanded: primarySectionExpanded,
                    canCreateProject: sidebarViewModel.currentVault != nil,
                    onToggleExpansion: togglePrimarySection,
                    onCreateProject: onCreateProject
                )
                .listRowSeparator(.hidden)

                if mainWindowNavigation.meetingSidebarDisplayMode == .chronological,
                   isRecentSectionExpanded {
                    if let selectedMeeting = selectedMeetingOutsideVisibleItems {
                        Section {
                            meetingRow(selectedMeeting)
                        } header: {
                            Text(sidebarViewModel.isSearchingMeetings ? L10n.selectedMeetingOutsideResults : L10n.selectedMeeting)
                                .font(.subheadline)
                        }
                    }

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
                } else if mainWindowNavigation.meetingSidebarDisplayMode == .byProject {
                    if isProjectSectionExpanded {
                        if let selectedMeeting = selectedMeetingOutsideVisibleItems {
                            Section {
                                meetingRow(selectedMeeting)
                            } header: {
                                Text(sidebarViewModel.isSearchingMeetings ? L10n.selectedMeetingOutsideResults : L10n.selectedMeeting)
                                    .font(.subheadline)
                            }
                        }

                        ForEach(unpinnedProjectGroups) { group in
                            projectSection(group, isPinned: false)
                        }
                    }

                    if let unassignedProjectGroup {
                        MeetingSidebarListGroupLabel(
                            title: L10n.recent,
                            isExpanded: isRecentSectionExpanded,
                            onToggleExpansion: { isRecentSectionExpanded.toggle() },
                            displayMode: $mainWindowNavigation.meetingSidebarDisplayMode,
                            textStyle: .body
                        )
                        if isRecentSectionExpanded {
                            projectSection(
                                unassignedProjectGroup,
                                isPinned: false,
                                showsHeader: false,
                                isExpanded: true
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.trailing, 12, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .overlay {
                if !hasExpandedContent {
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
        .font(.callout)
        .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
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

    private var primarySectionExpanded: Bool {
        mainWindowNavigation.meetingSidebarDisplayMode == .chronological
            ? isRecentSectionExpanded
            : isProjectSectionExpanded
    }

    private var hasExpandedContent: Bool {
        mainWindowNavigation.meetingSidebarDisplayMode == .chronological
            ? isRecentSectionExpanded
            : isProjectSectionExpanded || isRecentSectionExpanded
    }

    private func togglePrimarySection() {
        if mainWindowNavigation.meetingSidebarDisplayMode == .chronological {
            isRecentSectionExpanded.toggle()
        } else {
            isProjectSectionExpanded.toggle()
        }
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

    static func containsMeeting(_ meetingID: UUID, in groups: [MeetingProjectGroup]) -> Bool {
        groups.contains { group in
            group.meetings.contains { $0.meetingId == meetingID }
        }
    }

    private var unpinnedProjectGroups: [MeetingProjectGroup] {
        let pinnedIDs = Set(mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id))
        return sidebarViewModel.projectMeetingGroups.filter { group in
            group.project.map { !pinnedIDs.contains($0.projectId) } ?? false
        }
    }

    private var unassignedProjectGroup: MeetingProjectGroup? {
        sidebarViewModel.projectMeetingGroups.first { $0.key == .unassigned }
    }

    private var meetingListLimitMessage: String? {
        guard sidebarViewModel.isDisplayedMeetingListLimited else { return nil }
        return sidebarViewModel.isSearchingMeetings
            ? L10n.refineMeetingSearch
            : L10n.searchForOlderMeetings
    }

    private var selectedMeetingOutsideVisibleItems: MeetingSidebarItem? {
        guard let item = sidebarViewModel.selectedMeetingOutsideDisplayedItems else { return nil }
        guard !Self.containsMeeting(item.meetingId, in: pinnedProjectGroups) else { return nil }
        if mainWindowNavigation.meetingSidebarDisplayMode == .byProject,
           Self.containsMeeting(item.meetingId, in: sidebarViewModel.projectMeetingGroups) {
            return nil
        }
        return item
    }

    private func meetingRow(_ item: MeetingSidebarItem) -> some View {
        let projectAppearance = item.projectId.map {
            mainWindowNavigation.projectAppearance(
                projectId: $0,
                vaultId: sidebarViewModel.currentVault?.id
            )
        }
        return MeetingSidebarRow(
            item: item,
            projectTint: projectAppearance?.color.color,
            projectAppearance: projectAppearance,
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

    private func projectSection(
        _ group: MeetingProjectGroup,
        isPinned: Bool,
        showsHeader: Bool = true,
        isExpanded: Bool? = nil
    ) -> some View {
        MeetingSidebarProjectSection(
            group: group,
            showsHeader: showsHeader,
            projectAppearance: group.project.map {
                mainWindowNavigation.projectAppearance(
                    projectId: $0.projectId,
                    vaultId: sidebarViewModel.currentVault?.id
                )
            } ?? .default,
            isPinned: isPinned,
            isExpanded: isExpanded ?? !collapsedProjectKeys.contains(group.key),
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
