import GRDB
import SwiftUI

struct MeetingBreadcrumbList: View {
    let workspaceID: UUID
    let projectID: UUID?
    let dbQueue: DatabaseQueue?
    let onOpenMeeting: (UUID) -> Void

    @State private var items: [MeetingSidebarItem] = []
    @State private var nextCursor: MeetingSidebarCursor?
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var error: String?
    @State private var pageRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                BreadcrumbNavigationButton(title: item.displayTitle, systemImage: "doc.text") {
                    onOpenMeeting(item.meetingId)
                }
            }
            if isLoading {
                ProgressView(L10n.loadingMeetings).controlSize(.small)
            } else if let error {
                Button(L10n.retry) { pageRequest += 1 }.help(error)
            } else if hasMore {
                if items.count < SidebarViewModel.maximumVisibleMeetings {
                    Button(L10n.loadMore) { pageRequest += 1 }
                } else {
                    Text(L10n.projectMeetingLimitReached).font(.footnote).foregroundStyle(.secondary)
                }
            } else if items.isEmpty {
                Text(L10n.noMeetingsInProject).font(.body).foregroundStyle(.secondary)
            }
        }
        .task(id: pageRequest) {
            guard let dbQueue else {
                isLoading = false
                return
            }
            isLoading = true
            error = nil
            let key = projectID.map(MeetingProjectKey.project) ?? .unassigned
            let cursor = nextCursor
            let workspaceID = workspaceID
            let limit = min(20, SidebarViewModel.maximumVisibleMeetings - items.count)
            do {
                let page = try await dbQueue.read { db in
                    try MeetingRepository.fetchMeetingProjectPage(
                        key: key, workspaceId: workspaceID, after: cursor, limit: limit, in: db
                    )
                }
                try Task.checkCancellation()
                let knownIDs = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !knownIDs.contains($0.id) })
                nextCursor = page.nextCursor
                hasMore = page.hasMore
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}
