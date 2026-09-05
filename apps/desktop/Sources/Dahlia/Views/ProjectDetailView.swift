import GRDB
import SwiftUI

struct ProjectDetailView: View {
    let project: ProjectOverviewItem
    let projects: [ProjectOverviewItem]
    let appearance: ProjectAppearance
    let appearanceForProject: (UUID) -> ProjectAppearance
    let vaultID: UUID?
    let dbQueue: DatabaseQueue?
    let workspaceChangeToken: UInt64
    let displayMode: ProjectDetailDisplayMode
    let onChangeDisplayMode: (ProjectDetailDisplayMode) -> Void
    let onBack: () -> Void
    let canEdit: Bool
    let onEdit: () -> Void
    let onOpenMeeting: (UUID) -> Void

    @State private var model = ProjectDetailViewModel()
    @State private var displayedMonth = Date.now

    private var hierarchy: [ProjectOverviewItem] {
        [project] + projects.filter { $0.parentProjectId == project.projectId }
    }

    private var projectIDs: [UUID] { hierarchy.map(\.projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ProjectDetailToolbar(
                displayedMonth: $displayedMonth,
                displayMode: displayMode,
                onChangeDisplayMode: onChangeDisplayMode
            )

            if displayMode == .list {
                ProjectDetailListView(
                    items: model.listItems,
                    isLoading: model.isLoadingList,
                    hasMore: model.hasMoreListItems,
                    isLimited: model.isListLimited,
                    error: model.listError,
                    onOpenMeeting: onOpenMeeting,
                    onLoadMore: { Task { await model.loadMore() } }
                )
            } else {
                ProjectDetailCalendarView(
                    displayedMonth: displayedMonth,
                    items: model.calendarItems,
                    appearanceForProject: appearanceForProject,
                    isLoading: model.isLoadingCalendar,
                    isLimited: model.isCalendarLimited,
                    error: model.calendarError,
                    onOpenMeeting: onOpenMeeting,
                    onRetry: { Task { await loadCalendar() } }
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, DahliaDesign.detailTopPadding)
        .padding(.bottom, 24)
        .frame(maxWidth: DahliaDesign.mainContentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .task(id: ListLoadID(hierarchy: hierarchy, vaultID: vaultID, changeToken: workspaceChangeToken)) {
            await model.reload(projectIDs: projectIDs, vaultID: vaultID, dbQueue: dbQueue)
        }
        .task(id: CalendarLoadID(
            hierarchy: hierarchy,
            vaultID: vaultID,
            month: displayedMonth,
            changeToken: workspaceChangeToken,
            isVisible: displayMode == .calendar
        )) {
            guard displayMode == .calendar else { return }
            await loadCalendar()
        }
        .onChange(of: project.projectId) {
            displayedMonth = .now
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(L10n.projects, systemImage: "arrow.backward", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ProjectAppearanceIcon(appearance: appearance)
                    .font(.title2)

                Text(project.projectDisplayName)
                    .font(.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)

                if canEdit {
                    DahliaWindowHeaderIconButton(
                        label: L10n.editProject,
                        systemImage: "pencil",
                        presentsHelpInContainerOverlay: true,
                        controlSize: 36,
                        symbolFont: .title2,
                        action: onEdit
                    )
                }

                Spacer()
            }
        }
    }

    private func loadCalendar() async {
        await model.loadCalendar(
            containing: displayedMonth,
            projectIDs: projectIDs,
            vaultID: vaultID,
            dbQueue: dbQueue
        )
    }
}

private struct ListLoadID: Equatable {
    let hierarchy: [ProjectOverviewItem]
    let vaultID: UUID?
    let changeToken: UInt64
}

private struct CalendarLoadID: Equatable {
    let hierarchy: [ProjectOverviewItem]
    let vaultID: UUID?
    let month: Date
    let changeToken: UInt64
    let isVisible: Bool
}
