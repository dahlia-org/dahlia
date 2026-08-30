import Foundation
import GRDB

extension MeetingRepository {
    private struct ReferenceOwnerCount {
        let table: String
        let references: String
        let foreignKey: String
        let predicate: String

        static let projects = Self(
            table: "projects",
            references: "project_resource_references",
            foreignKey: "projectId",
            predicate: ""
        )
        static let topics = Self(
            table: "conversation_topics",
            references: "conversation_topic_references",
            foreignKey: "topicId",
            predicate: ""
        )
        static let unacceptedInsights = Self(
            table: "insights",
            references: "insight_references",
            foreignKey: "insightId",
            predicate: " AND owner.isAccepted = 0"
        )
    }

    nonisolated static func presentationCounts(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> CustomerIntelligenceWorkspaceData.Counts {
        try CustomerIntelligenceWorkspaceData.Counts(
            contacts: scopedContactCount(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
            projects: scopedReferenceOwnerCount(.projects, vaultId: vaultId, scopeIDs: scopeIDs, in: db),
            topics: scopedReferenceOwnerCount(.topics, vaultId: vaultId, scopeIDs: scopeIDs, in: db),
            meetings: scopedMeetingCount(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
            unacceptedInsights: scopedReferenceOwnerCount(
                .unacceptedInsights,
                vaultId: vaultId,
                scopeIDs: scopeIDs,
                in: db
            )
        )
    }

    nonisolated static func scopedContactCount(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> Int {
        guard let scopeIDs else {
            return try ContactRecord.filter(Column("vaultId") == vaultId).fetchCount(db)
        }
        guard !scopeIDs.contacts.isEmpty else { return 0 }
        var arguments: StatementArguments = [vaultId]
        arguments += StatementArguments(scopeIDs.contacts)
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM contacts
            WHERE vaultId = ? AND id IN (\(placeholders(scopeIDs.contacts.count)))
            """,
            arguments: arguments
        ) ?? 0
    }

    nonisolated static func scopedProjectCount(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> Int {
        try scopedReferenceOwnerCount(.projects, vaultId: vaultId, scopeIDs: scopeIDs, in: db)
    }

    nonisolated static func scopedTopicCount(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> Int {
        try scopedReferenceOwnerCount(.topics, vaultId: vaultId, scopeIDs: scopeIDs, in: db)
    }

    private nonisolated static func scopedReferenceOwnerCount(
        _ owner: ReferenceOwnerCount,
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> Int {
        var arguments: StatementArguments = [vaultId]
        var scopeFilter = ""
        if let scopeIDs {
            let filters = resourceReferenceFilters(
                table: "refs",
                organizationIDs: scopeIDs.organizations,
                contactIDs: scopeIDs.contacts,
                arguments: &arguments
            )
            guard !filters.isEmpty else { return 0 }
            scopeFilter = """
             AND EXISTS (
                 SELECT 1
                 FROM \(owner.references) AS refs
                 WHERE refs.\(owner.foreignKey) = owner.id
                   AND (\(filters.joined(separator: " OR ")))
             )
            """
        }
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM \(owner.table) AS owner
            WHERE owner.vaultId = ?\(owner.predicate)\(scopeFilter)
            """,
            arguments: arguments
        ) ?? 0
    }
}
