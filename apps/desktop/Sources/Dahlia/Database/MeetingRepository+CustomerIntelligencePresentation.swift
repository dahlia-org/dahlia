import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated func fetchCustomerIntelligenceOverview(
        vaultId: UUID,
        scope: CustomerIntelligenceScope
    ) throws -> CustomerIntelligenceWorkspaceData.Overview {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            let contacts = try Self.contactSummaries(
                vaultId: vaultId,
                contactID: nil,
                scopeIDs: scopeIDs,
                in: db
            )
            let projects = try Self.projectSummaries(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
            let topics = try Self.topicOverviews(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
            let insights = try Self.insightSummaries(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
            let meetings = try Self.scopedMeetings(vaultId: vaultId, scopeIDs: scopeIDs, limit: 8, in: db)
            let customers = try Self.customerCards(vaultId: vaultId, in: db)
            return try CustomerIntelligenceWorkspaceData.Overview(
                counts: Self.presentationCounts(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
                customers: customers,
                keyContacts: Array(
                    contacts
                        .sorted {
                            if $0.meetingCount != $1.meetingCount {
                                return $0.meetingCount > $1.meetingCount
                            }
                            return ($0.lastInteractionAt ?? .distantPast) > ($1.lastInteractionAt ?? .distantPast)
                        }
                        .prefix(6)
                ),
                recentProjects: Array(
                    projects
                        .sorted {
                            ($0.latestMeetingDate ?? $0.project.createdAt)
                                > ($1.latestMeetingDate ?? $1.project.createdAt)
                        }
                        .prefix(6)
                ),
                recentTopics: Array(topics.prefix(6)),
                recentMeetings: meetings,
                pendingInsights: Array(insights.filter { !$0.insight.isAccepted }.prefix(6))
            )
        }
    }

    nonisolated func fetchCustomerIntelligenceCounts(
        vaultId: UUID,
        scope: CustomerIntelligenceScope = .all
    ) throws -> CustomerIntelligenceWorkspaceData.Counts {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            return try Self.presentationCounts(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
        }
    }

    nonisolated func fetchCustomerIntelligenceCustomerCards(
        vaultId: UUID
    ) throws -> [CustomerIntelligenceWorkspaceData.CustomerCard] {
        try dbQueue.read { db in
            try Self.customerCards(vaultId: vaultId, in: db)
        }
    }

    nonisolated func fetchCustomerIntelligenceContacts(
        vaultId: UUID,
        scope: CustomerIntelligenceScope = .all
    ) throws -> [CustomerIntelligenceWorkspaceData.ContactSummary] {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            return try Self.contactSummaries(
                vaultId: vaultId,
                contactID: nil,
                scopeIDs: scopeIDs,
                in: db
            )
        }
    }

    nonisolated func fetchCustomerIntelligenceContactDetail(
        id: UUID,
        vaultId: UUID
    ) throws -> CustomerIntelligenceWorkspaceData.ContactDetail? {
        try dbQueue.read { db in
            guard let summary = try Self.contactSummaries(
                vaultId: vaultId,
                contactID: id,
                scopeIDs: nil,
                in: db
            ).first else {
                return nil
            }
            return try CustomerIntelligenceWorkspaceData.ContactDetail(
                summary: summary,
                memberships: Self.contactMemberships(id: id, vaultId: vaultId, in: db),
                projects: Self.contactProjects(id: id, vaultId: vaultId, in: db),
                recentMeetings: Self.contactMeetings(id: id, vaultId: vaultId, in: db),
                topics: Self.contactTopics(id: id, vaultId: vaultId, in: db)
            )
        }
    }

    nonisolated func fetchContact(
        vaultId: UUID,
        normalizedEmail: String
    ) throws -> ContactRecord? {
        try dbQueue.read { db in
            try ContactRecord
                .filter(Column("vaultId") == vaultId && Column("email") == normalizedEmail)
                .fetchOne(db)
        }
    }

    nonisolated func fetchConversationTopics(
        vaultId: UUID,
        organizationId: UUID?
    ) throws -> [ConversationTopicOverview] {
        try fetchConversationTopics(
            vaultId: vaultId,
            scope: organizationId.map(CustomerIntelligenceScope.organization) ?? .all
        )
    }

    nonisolated func fetchConversationTopics(
        vaultId: UUID,
        scope: CustomerIntelligenceScope
    ) throws -> [ConversationTopicOverview] {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            return try Self.topicOverviews(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
        }
    }

    nonisolated func fetchCustomerIntelligenceTopicDetail(
        id: UUID,
        vaultId: UUID
    ) throws -> CustomerIntelligenceWorkspaceData.TopicDetail? {
        try dbQueue.read { db in
            guard let overview = try Self.topicOverview(id: id, vaultId: vaultId, in: db) else {
                return nil
            }
            let references = try ConversationTopicReferenceRecord
                .filter(Column("topicId") == id)
                .order(Column("resourceType").asc, Column("createdAt").desc)
                .limit(100)
                .fetchAll(db)
            let links = try references.compactMap {
                try Self.resourceLink(
                    kind: CustomerIntelligenceResourceKind(rawValue: $0.resourceType.rawValue),
                    id: $0.resourceId,
                    role: nil,
                    note: $0.note,
                    vaultId: vaultId,
                    in: db
                )
            }
            return try CustomerIntelligenceWorkspaceData.TopicDetail(
                overview: overview,
                references: links.filter { $0.kind != .meeting },
                meetings: Self.topicMeetingEvidence(id: id, vaultId: vaultId, in: db)
            )
        }
    }

    nonisolated func fetchCustomerIntelligenceInsights(
        vaultId: UUID,
        scope: CustomerIntelligenceScope = .all
    ) throws -> [CustomerIntelligenceWorkspaceData.InsightSummary] {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            return try Self.insightSummaries(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
        }
    }

    nonisolated func fetchCustomerIntelligenceInsightDetail(
        id: UUID,
        vaultId: UUID
    ) throws -> CustomerIntelligenceWorkspaceData.InsightDetail? {
        try dbQueue.read { db in
            guard let summary = try Self.insightSummary(id: id, vaultId: vaultId, in: db) else {
                return nil
            }
            let references = try InsightReferenceRecord
                .filter(Column("insightId") == id)
                .order(Column("referenceRole").asc, Column("createdAt").desc)
                .fetchAll(db)
            let links = try references.compactMap {
                try Self.resourceLink(
                    kind: CustomerIntelligenceResourceKind(rawValue: $0.resourceType.rawValue),
                    id: $0.resourceId,
                    role: $0.referenceRole.rawValue,
                    note: nil,
                    vaultId: vaultId,
                    in: db
                )
            }
            return CustomerIntelligenceWorkspaceData.InsightDetail(
                summary: CustomerIntelligenceWorkspaceData.InsightSummary(
                    insight: summary.insight,
                    referenceCount: summary.referenceCount,
                    relatedTitles: Array(links.map(\.title).prefix(3))
                ),
                references: links
            )
        }
    }

    nonisolated func fetchCustomerIntelligenceProjects(
        vaultId: UUID,
        scope: CustomerIntelligenceScope = .all
    ) throws -> [CustomerIntelligenceWorkspaceData.ProjectSummary] {
        try dbQueue.read { db in
            let scopeIDs = try Self.presentationScopeIDs(vaultId: vaultId, scope: scope, in: db)
            return try Self.projectSummaries(vaultId: vaultId, scopeIDs: scopeIDs, in: db)
        }
    }

    nonisolated func fetchCustomerIntelligenceProjectDetail(
        id: UUID,
        vaultId: UUID
    ) throws -> CustomerIntelligenceWorkspaceData.ProjectDetail? {
        try dbQueue.read { db in
            guard let summary = try Self.projectSummaries(
                vaultId: vaultId,
                scopeIDs: nil,
                projectID: id,
                in: db
            ).first
            else {
                return nil
            }
            let references = try ProjectResourceReferenceRecord
                .filter(Column("projectId") == id)
                .order(Column("resourceType").asc, Column("relationLabel").asc)
                .fetchAll(db)
            let links = try references.compactMap {
                try Self.resourceLink(
                    kind: CustomerIntelligenceResourceKind(rawValue: $0.resourceType.rawValue),
                    id: $0.resourceId,
                    role: $0.relationLabel.nilIfBlank,
                    note: nil,
                    vaultId: vaultId,
                    in: db
                )
            }
            let meetings = try MeetingRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM meetings
                WHERE vaultId = ? AND projectId = ?
                ORDER BY COALESCE(recordingStartedAt, createdAt) DESC, id DESC
                LIMIT 25
                """,
                arguments: [vaultId, id]
            )
            return CustomerIntelligenceWorkspaceData.ProjectDetail(
                summary: summary,
                references: links,
                meetings: meetings
            )
        }
    }

}

extension MeetingRepository {
    struct PresentationScopeIDs {
        let organizations: [UUID]
        let contacts: [UUID]
    }

    nonisolated static func presentationScopeIDs(
        vaultId: UUID,
        scope: CustomerIntelligenceScope,
        in db: Database
    ) throws -> PresentationScopeIDs? {
        guard let rootID = scope.organizationID else { return nil }
        let organizations = try UUID.fetchAll(
            db,
            sql: """
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM organizations WHERE id = ? AND vaultId = ?
                UNION ALL
                SELECT child.id
                FROM organizations AS child
                JOIN descendants ON child.parentOrganizationId = descendants.id
                WHERE child.vaultId = ?
            )
            SELECT id FROM descendants
            """,
            arguments: [rootID, vaultId, vaultId]
        )
        guard !organizations.isEmpty else {
            return PresentationScopeIDs(organizations: [], contacts: [])
        }
        let contacts = try UUID.fetchAll(
            db,
            sql: """
            SELECT DISTINCT contactId
            FROM organization_memberships
            WHERE organizationId IN (\(placeholders(organizations.count)))
            """,
            arguments: StatementArguments(organizations)
        )
        return PresentationScopeIDs(organizations: organizations, contacts: contacts)
    }

    nonisolated static func customerCards(
        vaultId: UUID,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.CustomerCard] {
        let roots = try Row.fetchAll(
            db,
            sql: """
            SELECT organizations.*,
                   (SELECT COUNT(*) FROM organizations AS child
                    WHERE child.parentOrganizationId = organizations.id) AS childCount
            FROM organizations
            WHERE organizations.vaultId = ? AND organizations.parentOrganizationId IS NULL
            ORDER BY organizations.name COLLATE NOCASE, organizations.id
            LIMIT 500
            """,
            arguments: [vaultId]
        ).map {
            try OrganizationWorkspaceNode(
                organization: OrganizationRecord(row: $0),
                childCount: $0["childCount"]
            )
        }
        return try roots.map { root in
            let scopeIDs = try presentationScopeIDs(
                vaultId: vaultId,
                scope: .organization(root.id),
                in: db
            )
            let contacts = try contactSummaries(
                vaultId: vaultId,
                contactID: nil,
                scopeIDs: scopeIDs,
                in: db
            )
            return try CustomerIntelligenceWorkspaceData.CustomerCard(
                root: root,
                organizationCount: scopeIDs?.organizations.count ?? 0,
                contactCount: scopedContactCount(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
                projectCount: scopedProjectCount(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
                topicCount: scopedTopicCount(vaultId: vaultId, scopeIDs: scopeIDs, in: db),
                lastInteractionAt: contacts.compactMap(\.lastInteractionAt).max()
            )
        }
        .sorted {
            ($0.lastInteractionAt ?? .distantPast) > ($1.lastInteractionAt ?? .distantPast)
        }
    }

    nonisolated static func contactSummaries(
        vaultId: UUID,
        contactID: UUID?,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.ContactSummary] {
        var filters = ["contacts.vaultId = ?"]
        var arguments: StatementArguments = [vaultId]
        if let contactID {
            filters.append("contacts.id = ?")
            arguments += [contactID]
        }
        if let scopeIDs {
            guard !scopeIDs.contacts.isEmpty else { return [] }
            filters.append("contacts.id IN (\(placeholders(scopeIDs.contacts.count)))")
            arguments += StatementArguments(scopeIDs.contacts)
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT contacts.*,
                   COUNT(DISTINCT CASE WHEN meeting_participants.responseStatus <> 'declined'
                                      THEN meeting_participants.meetingId END) AS meetingCount,
                   MAX(CASE WHEN meeting_participants.responseStatus <> 'declined'
                            THEN COALESCE(meetings.recordingStartedAt, meetings.createdAt) END) AS lastInteractionAt,
                   COUNT(DISTINCT organization_memberships.organizationId) AS membershipCount,
                   COUNT(DISTINCT conversation_topic_references.topicId) AS topicCount
            FROM contacts
            LEFT JOIN meeting_participants ON meeting_participants.contactId = contacts.id
            LEFT JOIN meetings
              ON meetings.id = meeting_participants.meetingId
             AND meetings.vaultId = contacts.vaultId
            LEFT JOIN organization_memberships ON organization_memberships.contactId = contacts.id
            LEFT JOIN conversation_topic_references
              ON conversation_topic_references.resourceType = 'contact'
             AND conversation_topic_references.resourceId = contacts.id
            WHERE \(filters.joined(separator: " AND "))
            GROUP BY contacts.id
            ORDER BY COALESCE(contacts.displayName, contacts.email) COLLATE NOCASE, contacts.id
            LIMIT 500
            """,
            arguments: arguments
        )
        let ids: [UUID] = rows.map { $0["id"] }
        let membershipRows: [Row] = if ids.isEmpty {
            []
        } else {
            try Row.fetchAll(
                db,
                sql: """
                SELECT memberships.contactId, organizations.name, memberships.roleLabel
                FROM organization_memberships AS memberships
                JOIN organizations ON organizations.id = memberships.organizationId
                WHERE memberships.contactId IN (\(placeholders(ids.count)))
                ORDER BY organizations.name COLLATE NOCASE, organizations.id
                """,
                arguments: StatementArguments(ids)
            )
        }
        let memberships = Dictionary(grouping: membershipRows) { row -> UUID in row["contactId"] }
        return try rows.map { row in
            let id: UUID = row["id"]
            let related = memberships[id, default: []]
            return try CustomerIntelligenceWorkspaceData.ContactSummary(
                contact: ContactRecord(row: row),
                meetingCount: row["meetingCount"],
                lastInteractionAt: row["lastInteractionAt"],
                membershipCount: row["membershipCount"],
                organizationNames: related.map { $0["name"] },
                roleLabels: related.compactMap { $0["roleLabel"] },
                topicCount: row["topicCount"]
            )
        }
    }

    nonisolated static func contactMemberships(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.ContactMembership] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT organizations.*, organization_memberships.roleLabel
            FROM organization_memberships
            JOIN organizations ON organizations.id = organization_memberships.organizationId
            WHERE organization_memberships.contactId = ?
              AND organizations.vaultId = ?
            ORDER BY organizations.name COLLATE NOCASE, organizations.id
            """,
            arguments: [id, vaultId]
        ).map {
            try CustomerIntelligenceWorkspaceData.ContactMembership(
                organization: OrganizationRecord(row: $0),
                roleLabel: $0["roleLabel"]
            )
        }
    }

    nonisolated static func contactProjects(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.ResourceLink] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT projects.id, projects.name, refs.relationLabel
            FROM project_resource_references AS refs
            JOIN projects ON projects.id = refs.projectId
            WHERE refs.resourceType = 'contact'
              AND refs.resourceId = ?
              AND projects.vaultId = ?
            ORDER BY projects.name COLLATE NOCASE, projects.id
            """,
            arguments: [id, vaultId]
        )
        return rows.map {
            CustomerIntelligenceWorkspaceData.ResourceLink(
                kind: .project,
                resourceID: $0["id"],
                title: $0["name"],
                role: ($0["relationLabel"] as String?).flatMap(\.nilIfBlank),
                note: nil
            )
        }
    }

    nonisolated static func contactMeetings(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [MeetingRecord] {
        try MeetingRecord.fetchAll(
            db,
            sql: """
            SELECT meetings.*
            FROM meeting_participants
            JOIN meetings ON meetings.id = meeting_participants.meetingId
            WHERE meeting_participants.contactId = ?
              AND meetings.vaultId = ?
              AND meeting_participants.responseStatus <> 'declined'
            ORDER BY COALESCE(meetings.recordingStartedAt, meetings.createdAt) DESC, meetings.id
            LIMIT 25
            """,
            arguments: [id, vaultId]
        )
    }

    nonisolated static func contactTopics(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [ConversationTopicOverview] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT topics.*,
                   MAX(CASE WHEN refs.resourceType = 'meeting'
                            THEN COALESCE(meetings.recordingStartedAt, meetings.createdAt) END) AS lastDiscussedAt,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'meeting' THEN refs.resourceId END) AS meetingCount,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'organization' THEN refs.resourceId END)
                       AS organizationCount
            FROM conversation_topics AS topics
            JOIN conversation_topic_references AS contactRef
              ON contactRef.topicId = topics.id
             AND contactRef.resourceType = 'contact'
             AND contactRef.resourceId = ?
            LEFT JOIN conversation_topic_references AS refs ON refs.topicId = topics.id
            LEFT JOIN meetings
              ON refs.resourceType = 'meeting'
             AND meetings.id = refs.resourceId
             AND meetings.vaultId = topics.vaultId
            WHERE topics.vaultId = ?
            GROUP BY topics.id
            ORDER BY COALESCE(lastDiscussedAt, topics.updatedAt) DESC, topics.id DESC
            LIMIT 100
            """,
            arguments: [id, vaultId]
        ).map(presentationTopicOverview(from:))
    }

    nonisolated static func topicOverviews(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> [ConversationTopicOverview] {
        var scopeFilter = ""
        var arguments: StatementArguments = [vaultId]
        if let scopeIDs {
            let referenceFilters = resourceReferenceFilters(
                table: "scopeRef",
                organizationIDs: scopeIDs.organizations,
                contactIDs: scopeIDs.contacts,
                arguments: &arguments
            )
            guard !referenceFilters.isEmpty else { return [] }
            scopeFilter = """
             AND EXISTS (
                 SELECT 1 FROM conversation_topic_references AS scopeRef
                 WHERE scopeRef.topicId = topics.id
                   AND (\(referenceFilters.joined(separator: " OR ")))
             )
            """
        }
        return try Row.fetchAll(
            db,
            sql: """
            SELECT topics.*,
                   MAX(CASE WHEN refs.resourceType = 'meeting'
                            THEN COALESCE(meetings.recordingStartedAt, meetings.createdAt) END) AS lastDiscussedAt,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'meeting' THEN refs.resourceId END) AS meetingCount,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'organization' THEN refs.resourceId END)
                       AS organizationCount
            FROM conversation_topics AS topics
            LEFT JOIN conversation_topic_references AS refs ON refs.topicId = topics.id
            LEFT JOIN meetings
              ON refs.resourceType = 'meeting'
             AND meetings.id = refs.resourceId
             AND meetings.vaultId = topics.vaultId
            WHERE topics.vaultId = ?\(scopeFilter)
            GROUP BY topics.id
            ORDER BY COALESCE(lastDiscussedAt, topics.updatedAt) DESC, topics.id DESC
            LIMIT 500
            """,
            arguments: arguments
        ).map(presentationTopicOverview(from:))
    }

    nonisolated static func topicOverview(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> ConversationTopicOverview? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT topics.*,
                   MAX(CASE WHEN refs.resourceType = 'meeting'
                            THEN COALESCE(meetings.recordingStartedAt, meetings.createdAt) END) AS lastDiscussedAt,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'meeting' THEN refs.resourceId END) AS meetingCount,
                   COUNT(DISTINCT CASE WHEN refs.resourceType = 'organization' THEN refs.resourceId END)
                       AS organizationCount
            FROM conversation_topics AS topics
            LEFT JOIN conversation_topic_references AS refs ON refs.topicId = topics.id
            LEFT JOIN meetings
              ON refs.resourceType = 'meeting'
             AND meetings.id = refs.resourceId
             AND meetings.vaultId = topics.vaultId
            WHERE topics.id = ? AND topics.vaultId = ?
            GROUP BY topics.id
            """,
            arguments: [id, vaultId]
        ) else {
            return nil
        }
        return try presentationTopicOverview(from: row)
    }

    nonisolated static func presentationTopicOverview(from row: Row) throws -> ConversationTopicOverview {
        try ConversationTopicOverview(
            topic: ConversationTopicRecord(row: row),
            lastDiscussedAt: row["lastDiscussedAt"],
            meetingCount: row["meetingCount"],
            organizationCount: row["organizationCount"]
        )
    }

    nonisolated static func topicMeetingEvidence(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [ConversationTopicMeetingEvidence] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT meetings.*, refs.note AS topicNote
            FROM conversation_topic_references AS refs
            JOIN conversation_topics AS topics ON topics.id = refs.topicId
            JOIN meetings ON meetings.id = refs.resourceId
            WHERE refs.topicId = ?
              AND refs.resourceType = 'meeting'
              AND topics.vaultId = ?
              AND meetings.vaultId = topics.vaultId
            ORDER BY COALESCE(meetings.recordingStartedAt, meetings.createdAt) DESC, meetings.id
            """,
            arguments: [id, vaultId]
        ).map {
            try ConversationTopicMeetingEvidence(
                meeting: MeetingRecord(row: $0),
                note: $0["topicNote"]
            )
        }
    }

    nonisolated static func insightSummaries(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.InsightSummary] {
        var scopeFilter = ""
        var arguments: StatementArguments = [vaultId]
        if let scopeIDs {
            let referenceFilters = resourceReferenceFilters(
                table: "scopeRef",
                organizationIDs: scopeIDs.organizations,
                contactIDs: scopeIDs.contacts,
                arguments: &arguments
            )
            guard !referenceFilters.isEmpty else { return [] }
            scopeFilter = """
             AND EXISTS (
                 SELECT 1 FROM insight_references AS scopeRef
                 WHERE scopeRef.insightId = insights.id
                   AND (\(referenceFilters.joined(separator: " OR ")))
             )
            """
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT insights.*, COUNT(insight_references.insightId) AS referenceCount
            FROM insights
            LEFT JOIN insight_references ON insight_references.insightId = insights.id
            WHERE insights.vaultId = ?\(scopeFilter)
            GROUP BY insights.id
            ORDER BY insights.isAccepted ASC, insights.createdAt DESC, insights.id DESC
            LIMIT 500
            """,
            arguments: arguments
        )
        return try rows.map {
            let id: UUID = $0["id"]
            return try CustomerIntelligenceWorkspaceData.InsightSummary(
                insight: InsightRecord(row: $0),
                referenceCount: $0["referenceCount"],
                relatedTitles: insightRelatedTitles(id: id, vaultId: vaultId, in: db)
            )
        }
    }

    nonisolated static func insightSummary(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> CustomerIntelligenceWorkspaceData.InsightSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT insights.*, COUNT(insight_references.insightId) AS referenceCount
            FROM insights
            LEFT JOIN insight_references ON insight_references.insightId = insights.id
            WHERE insights.id = ? AND insights.vaultId = ?
            GROUP BY insights.id
            """,
            arguments: [id, vaultId]
        ) else {
            return nil
        }
        return try CustomerIntelligenceWorkspaceData.InsightSummary(
            insight: InsightRecord(row: row),
            referenceCount: row["referenceCount"],
            relatedTitles: insightRelatedTitles(id: id, vaultId: vaultId, in: db)
        )
    }

    nonisolated static func insightRelatedTitles(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> [String] {
        let references = try InsightReferenceRecord
            .filter(Column("insightId") == id)
            .order(Column("createdAt").desc)
            .limit(3)
            .fetchAll(db)
        return try references.compactMap {
            try resourceLink(
                kind: CustomerIntelligenceResourceKind(rawValue: $0.resourceType.rawValue),
                id: $0.resourceId,
                role: nil,
                note: nil,
                vaultId: vaultId,
                in: db
            )?.title
        }
    }

    nonisolated static func projectSummaries(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        projectID: UUID? = nil,
        in db: Database
    ) throws -> [CustomerIntelligenceWorkspaceData.ProjectSummary] {
        var arguments: StatementArguments = [vaultId, vaultId]
        var projectFilter = ""
        if let projectID {
            projectFilter = "AND hierarchy.id = ?"
            arguments += [projectID]
        }
        if let scopeIDs {
            let filters = resourceReferenceFilters(
                table: "scopeRef",
                organizationIDs: scopeIDs.organizations,
                contactIDs: scopeIDs.contacts,
                arguments: &arguments
            )
            guard !filters.isEmpty else { return [] }
            projectFilter += """
             AND EXISTS (
                 SELECT 1
                 FROM project_resource_references AS scopeRef
                 WHERE scopeRef.projectId = hierarchy.id
                   AND (\(filters.joined(separator: " OR ")))
             )
            """
        }
        arguments += [500]
        let projectRows = try Row.fetchAll(
            db,
            sql: """
            WITH RECURSIVE hierarchy AS (
                SELECT projects.*,
                       projects.name AS resolvedPath,
                       COALESCE(projects.projectType, 'undefined') AS effectiveProjectType
                FROM projects
                WHERE projects.vaultId = ?
                  AND projects.parentProjectId IS NULL

                UNION ALL

                SELECT children.*,
                       hierarchy.resolvedPath || '/' || children.name,
                       hierarchy.effectiveProjectType
                FROM projects AS children
                JOIN hierarchy ON hierarchy.id = children.parentProjectId
                WHERE children.vaultId = ?
            )
            SELECT hierarchy.*
            FROM hierarchy
            WHERE 1 = 1
              \(projectFilter)
            ORDER BY hierarchy.createdAt DESC, hierarchy.id DESC
            LIMIT ?
            """,
            arguments: arguments
        )
        let projectsWithTypes = try projectRows.map { row -> (ProjectRecord, ProjectType) in
            var project = try ProjectRecord(row: row)
            project.resolvedPath = row["resolvedPath"]
            let effectiveType = ProjectType(rawValue: row["effectiveProjectType"]) ?? .undefined
            return (project, effectiveType)
        }
        let projects = projectsWithTypes.map(\.0)
        guard !projects.isEmpty else { return [] }
        let projectIDs = projects.map(\.id)
        var aggregateArguments: StatementArguments = [vaultId]
        aggregateArguments += StatementArguments(projectIDs)
        let aggregateRows = try Row.fetchAll(
            db,
            sql: """
            SELECT projectId,
                   COUNT(*) AS meetingCount,
                   MAX(COALESCE(recordingStartedAt, createdAt)) AS latestMeetingDate
            FROM meetings
            WHERE vaultId = ? AND projectId IN (\(placeholders(projectIDs.count)))
            GROUP BY projectId
            """,
            arguments: aggregateArguments
        )
        let aggregates = Dictionary(uniqueKeysWithValues: aggregateRows.map { row -> (UUID, (Int, Date?)) in
            (row["projectId"], (row["meetingCount"], row["latestMeetingDate"]))
        })
        let referenceRows = try Row.fetchAll(
            db,
            sql: """
            SELECT projectId, resourceType, resourceId
            FROM project_resource_references
            WHERE projectId IN (\(placeholders(projectIDs.count)))
            """,
            arguments: StatementArguments(projectIDs)
        )
        let resourceIDs = Set(referenceRows.map { row -> UUID in row["resourceId"] })
        let labels = try resourceLabels(vaultId: vaultId, ids: resourceIDs, in: db)
        let references = Dictionary(grouping: referenceRows) { row -> UUID in row["projectId"] }
        let effectiveTypes = Dictionary(uniqueKeysWithValues: projectsWithTypes.map { ($0.0.id, $0.1) })
        return projects.map { project in
            let rows = references[project.id, default: []]
            let organizationNames = rows.compactMap { row -> String? in
                let type: String = row["resourceType"]
                let id: UUID = row["resourceId"]
                return type == CustomerResourceType.organization.rawValue ? labels[id] : nil
            }
            let contactNames = rows.compactMap { row -> String? in
                let type: String = row["resourceType"]
                let id: UUID = row["resourceId"]
                return type == CustomerResourceType.contact.rawValue ? labels[id] : nil
            }
            return CustomerIntelligenceWorkspaceData.ProjectSummary(
                project: project,
                effectiveType: effectiveTypes[project.id] ?? .undefined,
                organizationNames: organizationNames,
                contactNames: contactNames,
                meetingCount: aggregates[project.id]?.0 ?? 0,
                latestMeetingDate: aggregates[project.id]?.1
            )
        }.sorted {
            if $0.project.path == $1.project.path {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.project.path.utf8.lexicographicallyPrecedes($1.project.path.utf8)
        }
    }

    nonisolated static func scopedMeetings(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        limit: Int,
        in db: Database
    ) throws -> [MeetingRecord] {
        if let scopeIDs {
            guard !scopeIDs.contacts.isEmpty else { return [] }
            var arguments: StatementArguments = [vaultId]
            arguments += StatementArguments(scopeIDs.contacts)
            arguments += [limit]
            return try MeetingRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT meetings.*
                FROM meeting_participants
                JOIN meetings ON meetings.id = meeting_participants.meetingId
                WHERE meetings.vaultId = ?
                  AND meeting_participants.contactId IN (\(placeholders(scopeIDs.contacts.count)))
                  AND meeting_participants.responseStatus <> 'declined'
                ORDER BY COALESCE(meetings.recordingStartedAt, meetings.createdAt) DESC, meetings.id DESC
                LIMIT ?
                """,
                arguments: arguments
            )
        }
        return try MeetingRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM meetings
            WHERE vaultId = ?
            ORDER BY COALESCE(recordingStartedAt, createdAt) DESC, id DESC
            LIMIT ?
            """,
            arguments: [vaultId, limit]
        )
    }

    nonisolated static func scopedMeetingCount(
        vaultId: UUID,
        scopeIDs: PresentationScopeIDs?,
        in db: Database
    ) throws -> Int {
        if let scopeIDs {
            guard !scopeIDs.contacts.isEmpty else { return 0 }
            var arguments: StatementArguments = [vaultId]
            arguments += StatementArguments(scopeIDs.contacts)
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(DISTINCT meetings.id)
                FROM meeting_participants
                JOIN meetings ON meetings.id = meeting_participants.meetingId
                WHERE meetings.vaultId = ?
                  AND meeting_participants.contactId IN (\(placeholders(scopeIDs.contacts.count)))
                  AND meeting_participants.responseStatus <> 'declined'
                """,
                arguments: arguments
            ) ?? 0
        }
        return try MeetingRecord.filter(Column("vaultId") == vaultId).fetchCount(db)
    }

}
