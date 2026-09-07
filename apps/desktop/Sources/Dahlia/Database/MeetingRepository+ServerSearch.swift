import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func serverSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        dbQueue: DatabaseQueue,
        contentProvider: MeetingContentProvider = .shared
    ) async throws -> ServerSearchProjection {
        guard let source = try await dbQueue.read({ try MeetingContentProvider.SearchSource.read(vaultId: vaultId, in: $0) })
        else { throw TextContentError.unavailable }
        let result = try await contentProvider.searchAll(vaultId: vaultId, criteria: criteria, dbQueue: dbQueue)
        let projected = try await dbQueue.read { db in
            let known = try Dictionary(uniqueKeysWithValues: fetchMeetingSidebarItems(
                ids: result.meetings.map(\.id), vaultId: vaultId, in: db
            ).map { ($0.id, $0) })
            let pendingMeetingIds = try Set(UUID.fetchAll(db, sql: """
            SELECT meetings.id FROM meetings WHERE meetings.vaultId = ?
              AND meetings.id IN (\(result.meetings.map { _ in "?" }.joined(separator: ",")))
              AND \(pendingSearchMeetingSQL)
            """, arguments: [vaultId] + StatementArguments(result.meetings.map(\.id))))
            let pendingScreenshotIds = try Set(UUID.fetchAll(db, sql: """
            SELECT meeting_images.id FROM meeting_images JOIN meetings ON meetings.id = meeting_images.meetingId
            WHERE meetings.vaultId = ? AND meeting_images.id IN (\(result.screenshots.map { _ in "?" }.joined(separator: ",")))
              AND \(pendingSearchScreenshotSQL)
            """, arguments: [vaultId] + StatementArguments(result.screenshots.map(\.id))))
            let meetings = try result.meetings.filter { !pendingMeetingIds.contains($0.id) }.map { hit -> MeetingSidebarItem in
                // Metadata is synchronized even when searchable bodies are not retained.
                guard var item = known[hit.id] else { throw TextContentError.changed }
                item.meetingName = hit.title
                item.projectId = hit.projectId
                item.projectName = hit.projectPath
                item.createdAt = hit.date
                item.recordingStartedAt = nil
                item.searchMatchContext = .init(kind: .server, text: hit.snippet)
                return item
            }
            let screenshots = try result.screenshots.filter { !pendingScreenshotIds.contains($0.id) }.map { hit -> ScreenshotSearchResult in
                guard let meetingId = hit.meetingId,
                      let row = try Row.fetchOne(db, sql: """
                      SELECT s.mimeType FROM meeting_images s JOIN meetings m ON m.id = s.meetingId
                      WHERE s.id = ? AND m.id = ? AND m.vaultId = ? AND s.fileId = ?
                      """, arguments: [hit.id, meetingId, vaultId, hit.fileId]) else { throw TextContentError.changed }
                return ScreenshotSearchResult(
                    id: hit.id,
                    meetingID: meetingId,
                    meetingTitle: hit.title,
                    meetingDescription: "",
                    capturedAt: hit.date,
                    mimeType: row["mimeType"],
                    snippet: hit.snippet
                )
            }
            let localProjects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            let localProjectIds = Set(localProjects.map(\.id))
            let projects = try result.projects.map { hit in
                guard localProjectIds.contains(hit.id) else { throw TextContentError.changed }
                return ProjectOverviewItem(
                    projectId: hit.id,
                    projectName: hit.projectPath ?? hit.title,
                    projectDisplayName: hit.title,
                    createdAt: hit.date,
                    meetingCount: hit.meetingCount ?? 0,
                    latestMeetingDate: hit.date
                )
            }
            let pendingProjectIds = try Set(UUID.fetchAll(db, sql: """
            SELECT p.id FROM projects p WHERE p.vaultId = ? AND (
              NOT EXISTS (SELECT 1 FROM sync_entity_state s WHERE s.vaultId = p.vaultId
                AND s.entity = 'project' AND s.entityId = p.id AND s.confirmedRevision IS NOT NULL)
              OR EXISTS (SELECT 1 FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.vaultId = p.vaultId AND o.entity = 'project' AND o.entityId = p.id))
            """, arguments: [vaultId]))
            let roots = localProjects.filter { criteria.projectIDs.contains($0.id) }.map(\.path)
            let terms = criteria.text.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace)
            let pendingProjects = try localProjects.filter { project in
                let normalizedPath = project.path.precomposedStringWithCompatibilityMapping.lowercased()
                guard pendingProjectIds.contains(project.id),
                      criteria.projectIDs.isEmpty || roots.contains(where: { project.path == $0 || project.path.hasPrefix($0 + "/") }),
                      terms.allSatisfy({ normalizedPath.contains($0) }) else { return false }
                if criteria.startDate != nil || criteria.endDate != nil {
                    let descendants = localProjects.filter { $0.path == project.path || $0.path.hasPrefix(project.path + "/") }.map(\.id)
                    return try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM meetings WHERE projectId IN (\(descendants.map { _ in "?" }.joined(separator: ",")))
                      AND (? IS NULL OR createdAt >= ?) AND (? IS NULL OR createdAt < ?))
                    """, arguments: StatementArguments(descendants) + [criteria.startDate, criteria.startDate, criteria.endDate, criteria.endDate]) == true
                }
                return true
            }.prefix(101).map { project in
                ProjectOverviewItem(
                    projectId: project.id,
                    projectName: project.path,
                    projectDisplayName: project.name,
                    createdAt: project.createdAt,
                    meetingCount: 0
                )
            }
            return (
                meetings: meetings,
                screenshots: screenshots,
                projects: projects.filter { !pendingProjectIds.contains($0.id) },
                pendingProjects: pendingProjects
            )
        }
        var pendingCriteria = criteria
        pendingCriteria.pendingOnly = true
        var pendingMeetings: [MeetingSidebarItem] = []
        var pendingScreenshots: [ScreenshotSearchResult] = []
        var pendingUnavailable = false
        var limited = result.limited.any || projected.pendingProjects.count > 100
        do {
            let pending = try await searchMeetingSidebarPage(vaultId: vaultId, criteria: pendingCriteria, limit: 100, dbQueue: dbQueue)
            pendingMeetings = pending.items
            limited = limited || pending.hasMore
            let images = try await searchScreenshotPage(vaultID: vaultId, criteria: pendingCriteria, limit: 100, dbQueue: dbQueue)
            pendingScreenshots = images.items
            limited = limited || images.nextCursor != nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A rebuildable local index must not hide available canonical search results.
            pendingUnavailable = true
        }
        try Task.checkCancellation()
        guard try await dbQueue.read({ try MeetingContentProvider.SearchSource.read(vaultId: vaultId, in: $0) }) == source
        else { throw TextContentError.changed }
        return ServerSearchProjection(
            meetings: projected.meetings,
            screenshots: projected.screenshots, projects: projected.projects,
            pendingMeetings: pendingMeetings, pendingScreenshots: pendingScreenshots,
            limited: limited, pendingProjects: Array(projected.pendingProjects.prefix(100)), pendingUnavailable: pendingUnavailable
        )
    }

    nonisolated static let pendingSearchScreenshotSQL = """
    (\(pendingSearchMeetingSQL)
    OR NOT EXISTS (SELECT 1 FROM sync_entity_state s WHERE s.vaultId = meetings.vaultId
        AND s.entity = 'meeting_file' AND s.entityId = meeting_images.id AND s.confirmedRevision IS NOT NULL)
    OR EXISTS (SELECT 1 FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
        WHERE t.vaultId = meetings.vaultId AND ((o.entity = 'file' AND o.entityId = meeting_images.fileId)
            OR (o.entity = 'meeting_file' AND o.entityId = meeting_images.id))))
    """

    nonisolated static let pendingSearchMeetingSQL = """
    (NOT EXISTS (SELECT 1 FROM sync_entity_state s
      WHERE s.vaultId = meetings.vaultId AND s.entity = 'meeting'
        AND s.entityId = meetings.id AND s.confirmedRevision IS NOT NULL)
    OR EXISTS (SELECT 1 FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
      WHERE t.vaultId = meetings.vaultId AND o.entity IN ('meeting', 'summary', 'transcript') AND o.entityId = meetings.id))
    """
}
