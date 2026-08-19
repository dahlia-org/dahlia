import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class ProjectDetailViewModel {
    private(set) var listItems: [MeetingSidebarItem] = []
    private(set) var calendarItems: [MeetingSidebarItem] = []
    private(set) var hasMoreListItems = false
    private(set) var isListLimited = false
    private(set) var isCalendarLimited = false
    private(set) var isLoadingList = false
    private(set) var isLoadingCalendar = false
    private(set) var listError: String?
    private(set) var calendarError: String?

    @ObservationIgnored private var projectIDs: [UUID] = []
    @ObservationIgnored private var vaultID: UUID?
    @ObservationIgnored private var dbQueue: DatabaseQueue?
    @ObservationIgnored private var listLoadGeneration: UInt64 = 0
    @ObservationIgnored private var calendarLoadGeneration: UInt64 = 0

    func reload(projectIDs: [UUID], vaultID: UUID?, dbQueue: DatabaseQueue?) async {
        listLoadGeneration &+= 1
        let generation = listLoadGeneration
        self.projectIDs = projectIDs
        self.vaultID = vaultID
        self.dbQueue = dbQueue
        listItems = []
        hasMoreListItems = false
        isListLimited = false
        isLoadingList = false
        listError = nil
        await loadMore(generation: generation)
    }

    func loadMore() async {
        await loadMore(generation: listLoadGeneration)
    }

    private func loadMore(generation: UInt64) async {
        guard generation == listLoadGeneration,
              !isLoadingList, !isListLimited,
              let vaultID, let dbQueue else { return }
        let projectIDs = projectIDs
        let cursor = listItems.last.map(MeetingSidebarCursor.init)
        isLoadingList = true
        listError = nil
        defer {
            if generation == listLoadGeneration {
                isLoadingList = false
            }
        }
        do {
            let remaining = SidebarViewModel.maximumVisibleMeetings - listItems.count
            guard remaining > 0 else {
                isListLimited = hasMoreListItems
                hasMoreListItems = false
                return
            }
            let page = try await Self.fetchPage(
                projectIDs: projectIDs,
                vaultID: vaultID,
                after: cursor,
                limit: min(SidebarViewModel.meetingPageSize, remaining),
                dbQueue: dbQueue
            )
            guard generation == listLoadGeneration else { return }
            listItems.append(contentsOf: page.items)
            isListLimited = page.hasMore && listItems.count >= SidebarViewModel.maximumVisibleMeetings
            hasMoreListItems = page.hasMore && !isListLimited
        } catch is CancellationError {
            return
        } catch {
            guard generation == listLoadGeneration else { return }
            listError = error.localizedDescription
        }
    }

    func loadCalendar(
        containing month: Date,
        projectIDs: [UUID],
        vaultID: UUID?,
        dbQueue: DatabaseQueue?,
        calendar: Calendar = .current
    ) async {
        calendarLoadGeneration &+= 1
        let generation = calendarLoadGeneration
        calendarItems = []
        isCalendarLimited = false
        isLoadingCalendar = false
        calendarError = nil
        guard let interval = ProjectCalendarMonth.interval(containing: month, calendar: calendar),
              let vaultID, let dbQueue else { return }
        isLoadingCalendar = true
        defer {
            if generation == calendarLoadGeneration {
                isLoadingCalendar = false
            }
        }
        do {
            let page = try await Self.fetchPage(
                projectIDs: projectIDs,
                vaultID: vaultID,
                dateInterval: interval,
                limit: SidebarViewModel.maximumVisibleMeetings,
                dbQueue: dbQueue
            )
            guard generation == calendarLoadGeneration else { return }
            calendarItems = page.items
            isCalendarLimited = page.hasMore
        } catch is CancellationError {
            return
        } catch {
            guard generation == calendarLoadGeneration else { return }
            calendarError = error.localizedDescription
        }
    }

    private nonisolated static func fetchPage(
        projectIDs: [UUID],
        vaultID: UUID,
        dateInterval: DateInterval? = nil,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSidebarPage {
        let task = Task.detached(priority: .userInitiated) {
            try dbQueue.read { db in
                try MeetingRepository.fetchProjectHierarchyMeetingPage(
                    projectIds: projectIDs,
                    vaultId: vaultID,
                    dateInterval: dateInterval,
                    after: cursor,
                    limit: limit,
                    in: db
                )
            }
        }
        let page = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return page
    }
}
