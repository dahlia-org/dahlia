import SwiftUI

struct MeetingSidebarProjectSection: View {
    let group: MeetingProjectGroup
    let showsHeader: Bool
    let projectAppearance: ProjectAppearance
    let isPinned: Bool
    let isExpanded: Bool
    let canCreateMeeting: Bool
    let showsMeetingDate: Bool
    let selectedMeetingIDs: Set<UUID>
    let activeRecordingID: UUID?
    let editingMeetingId: UUID?
    @Binding var editingMeetingName: String
    @FocusState.Binding var isRenameFieldFocused: Bool
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onToggleExpansion: () -> Void
    let allowsListSelection: Bool
    let onSelectMeeting: (UUID) -> Void
    let onOpenProject: (UUID, ProjectNavigationIntent) -> Void
    let onTogglePin: (UUID) -> Void
    let onCreateMeeting: (ProjectOverviewItem) -> Void
    let onLoadMore: (MeetingProjectKey) -> Void

    @State private var isLoadMoreHovered = false
    @State private var isNoProjectHovered = false

    var body: some View {
        if showsHeader {
            if let project = group.project {
                MeetingSidebarProjectHeader(
                    project: project,
                    appearance: projectAppearance,
                    isPinned: isPinned,
                    isExpanded: isExpanded,
                    canCreateMeeting: canCreateMeeting,
                    onToggleExpansion: onToggleExpansion,
                    onOpen: { onOpenProject(project.projectId, $0) },
                    onTogglePin: { onTogglePin(project.projectId) },
                    onCreateMeeting: { onCreateMeeting(project) }
                )
            } else {
                Button(action: onToggleExpansion) {
                    Label(
                        L10n.noProject,
                        systemImage: isExpanded ? "questionmark.folder" : "questionmark.folder.fill"
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
                .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
                .dahliaSidebarHoverHighlight(isHovered: isNoProjectHovered, verticalOutset: 2)
                .contentShape(.rect)
                .onHover { isNoProjectHovered = $0 }
                .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
            }
        }

        if isExpanded {
            projectContents
        }
    }

    @ViewBuilder
    private var projectContents: some View {
        if group.meetings.isEmpty, group.loadError == nil, group.isLoadingMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if group.meetings.isEmpty, group.isLimited {
            limitMessage
        } else if group.meetings.isEmpty, group.loadError == nil {
            Text(L10n.noMeetingsInProject)
                .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        } else {
            ForEach(group.meetings) { item in
                meetingRow(item)
            }
        }

        if let error = group.loadError {
            Button(L10n.retry, systemImage: "arrow.clockwise") {
                onLoadMore(group.key)
            }
            .help(error)
        } else if group.isLoadingMore, !group.meetings.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if group.hasMore {
            Button(action: { onLoadMore(group.key) }) {
                Text(L10n.loadMore)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 25)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
            .contentShape(.rect)
            .dahliaSidebarHoverHighlight(isHovered: isLoadMoreHovered)
            .onHover { isLoadMoreHovered = $0 }
        } else if group.isLimited {
            limitMessage
        }
    }

    private var limitMessage: some View {
        Text(L10n.searchForOlderMeetings)
            .font(.footnote)
            .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
            .padding(.leading, 25)
    }

    @ViewBuilder
    private func meetingRow(_ item: MeetingSidebarItem) -> some View {
        if allowsListSelection {
            meetingRowContent(item)
                .tag(item.meetingId)
        } else {
            Button(action: { onSelectMeeting(item.meetingId) }) {
                meetingRowContent(item)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedMeetingIDs.contains(item.meetingId) ? .isSelected : [])
        }
    }

    private func meetingRowContent(_ item: MeetingSidebarItem) -> some View {
        MeetingSidebarRow(
            item: item,
            contentLeadingPadding: 20,
            projectTint: nil,
            projectAppearance: projectAppearance,
            showsProjectChip: false,
            showsDateInTimestamp: showsMeetingDate,
            searchText: "",
            isSelected: selectedMeetingIDs.contains(item.meetingId),
            isActiveRecording: item.meetingId == activeRecordingID,
            isEditing: allowsListSelection && editingMeetingId == item.meetingId,
            editingName: $editingMeetingName,
            isFocused: $isRenameFieldFocused,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        )
    }
}
