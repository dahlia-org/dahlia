import Foundation

struct MeetingProjectGroup: Identifiable, Equatable, Sendable {
    let key: MeetingProjectKey
    let project: ProjectOverviewItem?
    let meetings: [MeetingSidebarItem]
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadError: String?
    let isLimited: Bool

    var id: MeetingProjectKey { key }
}
