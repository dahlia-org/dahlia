import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated func customerIntelligenceScopeContains(
        section: CustomerIntelligenceSection,
        resourceID: UUID,
        vaultId: UUID,
        scope: CustomerIntelligenceScope
    ) throws -> Bool {
        try dbQueue.read { db in
            guard let scopeIDs = try Self.presentationScopeIDs(
                vaultId: vaultId,
                scope: scope,
                in: db
            ) else {
                return true
            }
            if section == .contacts {
                return scopeIDs.contacts.contains(resourceID)
            }
            let owner: (table: String, id: String, references: String, foreignKey: String)
            switch section {
            case .projects:
                owner = ("projects", "id", "project_resource_references", "projectId")
            case .topics:
                owner = ("conversation_topics", "id", "conversation_topic_references", "topicId")
            case .insights:
                owner = ("insights", "id", "insight_references", "insightId")
            case .overview, .organizations, .contacts:
                return false
            }
            var arguments: StatementArguments = [resourceID, vaultId]
            let filters = Self.resourceReferenceFilters(
                table: "refs",
                organizationIDs: scopeIDs.organizations,
                contactIDs: scopeIDs.contacts,
                arguments: &arguments
            )
            guard !filters.isEmpty else { return false }
            return try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM \(owner.table) AS owner
                    JOIN \(owner.references) AS refs ON refs.\(owner.foreignKey) = owner.\(owner.id)
                    WHERE owner.\(owner.id) = ?
                      AND owner.vaultId = ?
                      AND (\(filters.joined(separator: " OR ")))
                )
                """,
                arguments: arguments
            ) ?? false
        }
    }

    nonisolated static func resourceReferenceFilters(
        table: String,
        organizationIDs: [UUID],
        contactIDs: [UUID],
        arguments: inout StatementArguments
    ) -> [String] {
        var filters: [String] = []
        if !organizationIDs.isEmpty {
            filters.append(
                "(\(table).resourceType = 'organization' AND \(table).resourceId IN (\(placeholders(organizationIDs.count))))"
            )
            arguments += StatementArguments(organizationIDs)
        }
        if !contactIDs.isEmpty {
            filters.append(
                "(\(table).resourceType = 'contact' AND \(table).resourceId IN (\(placeholders(contactIDs.count))))"
            )
            arguments += StatementArguments(contactIDs)
        }
        return filters
    }

    nonisolated static func resourceLabels(
        vaultId: UUID,
        ids: Set<UUID>,
        in db: Database
    ) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        var labels: [UUID: String] = [:]
        for organization in try OrganizationRecord
            .filter(Column("vaultId") == vaultId && ids.contains(Column("id")))
            .fetchAll(db) {
            labels[organization.id] = organization.name
        }
        for contact in try ContactRecord
            .filter(Column("vaultId") == vaultId && ids.contains(Column("id")))
            .fetchAll(db) {
            labels[contact.id] = contact.displayName ?? contact.email
        }
        for project in try ProjectRecord
            .filter(Column("vaultId") == vaultId && ids.contains(Column("id")))
            .fetchAll(db) {
            labels[project.id] = project.name
        }
        for meeting in try MeetingRecord
            .filter(Column("vaultId") == vaultId && ids.contains(Column("id")))
            .fetchAll(db) {
            labels[meeting.id] = meeting.name
        }
        for topic in try ConversationTopicRecord
            .filter(Column("vaultId") == vaultId && ids.contains(Column("id")))
            .fetchAll(db) {
            labels[topic.id] = topic.title
        }
        return labels
    }

    nonisolated static func resourceLink(
        kind: CustomerIntelligenceResourceKind?,
        id: UUID,
        role: String?,
        note: String?,
        vaultId: UUID,
        in db: Database
    ) throws -> CustomerIntelligenceWorkspaceData.ResourceLink? {
        guard let kind else { return nil }
        let title: String? = switch kind {
        case .organization:
            try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .select(Column("name"))
                .asRequest(of: String.self)
                .fetchOne(db)
        case .contact:
            if let contact = try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db) {
                contact.displayName ?? contact.email
            } else {
                nil
            }
        case .project:
            try ProjectRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .select(Column("name"))
                .asRequest(of: String.self)
                .fetchOne(db)
        case .meeting:
            try MeetingRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .select(Column("name"))
                .asRequest(of: String.self)
                .fetchOne(db)
        case .topic:
            try ConversationTopicRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .select(Column("title"))
                .asRequest(of: String.self)
                .fetchOne(db)
        }
        guard let title else { return nil }
        return CustomerIntelligenceWorkspaceData.ResourceLink(
            kind: kind,
            resourceID: id,
            title: title,
            role: role,
            note: note
        )
    }

    nonisolated static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
