import Foundation
import GRDB

/// Projects ワークスペースに表示する一覧用の集約モデル。
struct ProjectOverviewItem: Decodable, Equatable, FetchableRecord, Identifiable, Sendable {
    var projectId: UUID
    var projectName: String
    var projectDisplayName = ""
    var parentProjectId: UUID?
    var projectDescription = ""
    var explicitProjectType: ProjectType?
    var effectiveProjectType: ProjectType = .undefined
    var typeOwnerProjectId: UUID?
    var revision = 1
    var createdAt: Date
    var meetingCount: Int
    var latestMeetingDate: Date?

    var id: UUID { projectId }
}
