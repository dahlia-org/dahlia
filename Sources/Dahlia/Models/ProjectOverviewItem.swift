import Foundation
import GRDB

/// Projects ワークスペースに表示する一覧用の集約モデル。
struct ProjectOverviewItem: Decodable, Equatable, FetchableRecord, Identifiable {
    var projectId: UUID
    var projectName: String
    var projectLeafName = ""
    var parentProjectId: UUID?
    var projectDescription = ""
    var explicitProjectType: ProjectType?
    var effectiveProjectType: ProjectType = .undefined
    var typeOwnerProjectId: UUID?
    var revision = 1
    var createdAt: Date
    var missingOnDisk: Bool
    var meetingCount: Int
    var latestMeetingDate: Date?

    var id: UUID { projectId }
}
