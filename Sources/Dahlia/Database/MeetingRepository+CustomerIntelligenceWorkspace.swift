import DahliaRuntimeSupport
import Foundation
import GRDB

// swiftlint:disable file_length

extension MeetingRepository {
    nonisolated func fetchRootOrganizationWorkspaceNodes(vaultId: UUID) throws -> [OrganizationWorkspaceNode] {
        try dbQueue.read { db in
            try Self.organizationWorkspaceNodes(
                where: "organizations.vaultId = ? AND organizations.parentOrganizationId IS NULL",
                arguments: [vaultId],
                limit: 500,
                offset: 0,
                in: db
            )
        }
    }

    nonisolated func fetchOrganizationWorkspaceChildren(
        parentId: UUID,
        vaultId: UUID,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [OrganizationWorkspaceNode] {
        try dbQueue.read { db in
            try Self.organizationWorkspaceNodes(
                where: "organizations.vaultId = ? AND organizations.parentOrganizationId = ?",
                arguments: [vaultId, parentId],
                limit: min(max(limit, 1), 100),
                offset: max(offset, 0),
                in: db
            )
        }
    }

    nonisolated func fetchOrganizationWorkspacePath(id: UUID, vaultId: UUID) throws -> [OrganizationWorkspaceNode] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                WITH RECURSIVE ancestors(id, parentOrganizationId, depth) AS (
                    SELECT id, parentOrganizationId, 0
                    FROM organizations WHERE id = ? AND vaultId = ?
                    UNION ALL
                    SELECT parent.id, parent.parentOrganizationId, ancestors.depth + 1
                    FROM organizations AS parent
                    JOIN ancestors ON ancestors.parentOrganizationId = parent.id
                    WHERE parent.vaultId = ? AND ancestors.depth < 32
                )
                SELECT organizations.*,
                       (SELECT COUNT(*) FROM organizations AS child
                        WHERE child.parentOrganizationId = organizations.id) AS childCount,
                       ancestors.depth
                FROM ancestors
                JOIN organizations ON organizations.id = ancestors.id
                ORDER BY ancestors.depth DESC
                """,
                arguments: [id, vaultId, vaultId]
            ).map {
                try OrganizationWorkspaceNode(
                    organization: OrganizationRecord(row: $0),
                    childCount: $0["childCount"]
                )
            }
        }
    }

    nonisolated func fetchConversationTopicRelatedOrganizationPaths(
        id: UUID,
        vaultId: UUID,
        limit: Int = 100
    ) throws -> (paths: [[OrganizationWorkspaceNode]], isTruncated: Bool) {
        try dbQueue.read { db in
            let boundedLimit = min(max(limit, 1), 100)
            let relatedIDs = try UUID.fetchAll(
                db,
                sql: """
                SELECT resourceId
                FROM (
                    SELECT refs.resourceId
                    FROM conversation_topic_references AS refs
                    JOIN organizations ON organizations.id = refs.resourceId
                    WHERE refs.topicId = ?
                      AND refs.resourceType = 'organization'
                      AND organizations.vaultId = ?
                    UNION
                    SELECT memberships.organizationId
                    FROM conversation_topic_references AS refs
                    JOIN contacts ON contacts.id = refs.resourceId
                    JOIN organization_memberships AS memberships ON memberships.contactId = contacts.id
                    JOIN organizations ON organizations.id = memberships.organizationId
                    WHERE refs.topicId = ?
                      AND refs.resourceType = 'contact'
                      AND contacts.vaultId = ?
                      AND organizations.vaultId = ?
                )
                ORDER BY resourceId
                LIMIT ?
                """,
                arguments: [id, vaultId, id, vaultId, vaultId, boundedLimit + 1]
            )
            let isTruncated = relatedIDs.count > boundedLimit
            let targetIDs = Array(relatedIDs.prefix(boundedLimit))
            guard !targetIDs.isEmpty else { return ([], isTruncated) }

            let placeholders = targetIDs.map { _ in "?" }.joined(separator: ",")
            var arguments: StatementArguments = [vaultId]
            arguments += StatementArguments(targetIDs)
            arguments += [vaultId]
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH RECURSIVE ancestors(targetId, id, parentOrganizationId, depth) AS (
                    SELECT id, id, parentOrganizationId, 0
                    FROM organizations
                    WHERE vaultId = ? AND id IN (\(placeholders))
                    UNION ALL
                    SELECT ancestors.targetId, parent.id, parent.parentOrganizationId, ancestors.depth + 1
                    FROM organizations AS parent
                    JOIN ancestors ON ancestors.parentOrganizationId = parent.id
                    WHERE parent.vaultId = ? AND ancestors.depth < 32
                )
                SELECT ancestors.targetId,
                       organizations.*,
                       (SELECT COUNT(*) FROM organizations AS child
                        WHERE child.parentOrganizationId = organizations.id) AS childCount,
                       ancestors.depth
                FROM ancestors
                JOIN organizations ON organizations.id = ancestors.id
                ORDER BY ancestors.targetId, ancestors.depth DESC
                """,
                arguments: arguments
            )
            let grouped = Dictionary(grouping: rows) { row -> UUID in
                row["targetId"]
            }
            let paths: [[OrganizationWorkspaceNode]] = try targetIDs.compactMap { targetID in
                guard let pathRows = grouped[targetID] else { return nil }
                return try pathRows.map {
                    try OrganizationWorkspaceNode(
                        organization: OrganizationRecord(row: $0),
                        childCount: $0["childCount"]
                    )
                }
            }
            return (paths, isTruncated)
        }
    }

    nonisolated func searchOrganizationWorkspaceNodes(
        vaultId: UUID,
        rootOrganizationId: UUID? = nil,
        query: String,
        limit: Int = 50
    ) throws -> [OrganizationRecord] {
        try dbQueue.read { db in
            if let rootOrganizationId {
                return try OrganizationRecord.fetchAll(
                    db,
                    sql: """
                    WITH RECURSIVE subtree(id) AS (
                        SELECT id
                        FROM organizations
                        WHERE id = ? AND vaultId = ?
                        UNION ALL
                        SELECT child.id
                        FROM organizations AS child
                        JOIN subtree ON child.parentOrganizationId = subtree.id
                        WHERE child.vaultId = ?
                    )
                    SELECT organizations.*
                    FROM organizations
                    JOIN subtree ON subtree.id = organizations.id
                    WHERE (
                        organizations.name LIKE ?
                        OR organizations.description LIKE ?
                    )
                    ORDER BY organizations.name COLLATE NOCASE, organizations.id
                    LIMIT ?
                    """,
                    arguments: [
                        rootOrganizationId,
                        vaultId,
                        vaultId,
                        "%\(query)%",
                        "%\(query)%",
                        min(max(limit, 1), 100),
                    ]
                )
            }
            return try OrganizationRecord
                .filter(Column("vaultId") == vaultId)
                .filter(
                    Column("name").like("%\(query)%")
                        || Column("description").like("%\(query)%")
                )
                .order(Column("name").asc, Column("id").asc)
                .limit(min(max(limit, 1), 100))
                .fetchAll(db)
        }
    }

    nonisolated func fetchOrganizationWorkspaceSubtree(
        rootOrganizationId: UUID,
        vaultId: UUID,
        limit: Int = 1000
    ) throws -> [OrganizationRecord] {
        try dbQueue.read { db in
            try OrganizationRecord.fetchAll(
                db,
                sql: """
                WITH RECURSIVE subtree(id) AS (
                    SELECT id
                    FROM organizations
                    WHERE id = ? AND vaultId = ?
                    UNION ALL
                    SELECT child.id
                    FROM organizations AS child
                    JOIN subtree ON child.parentOrganizationId = subtree.id
                    WHERE child.vaultId = ?
                )
                SELECT organizations.*
                FROM organizations
                JOIN subtree ON subtree.id = organizations.id
                ORDER BY organizations.name COLLATE NOCASE, organizations.id
                LIMIT ?
                """,
                arguments: [
                    rootOrganizationId,
                    vaultId,
                    vaultId,
                    min(max(limit, 1), 1000),
                ]
            )
        }
    }

    nonisolated func fetchOrganizationWorkspaceDetail(
        organizationId: UUID,
        vaultId: UUID
    ) throws -> OrganizationWorkspaceDetail {
        try dbQueue.read { db in
            let domains = try OrganizationDomainRecord
                .filter(Column("organizationId") == organizationId && Column("vaultId") == vaultId)
                .order(Column("isPrimary").desc, Column("domainName").asc)
                .fetchAll(db)
            let memberRows = try Row.fetchAll(
                db,
                sql: """
                SELECT contacts.*, organization_memberships.roleLabel AS membershipRoleLabel
                FROM organization_memberships
                JOIN contacts ON contacts.id = organization_memberships.contactId
                WHERE organization_memberships.organizationId = ?
                  AND contacts.vaultId = ?
                ORDER BY COALESCE(contacts.displayName, contacts.email) COLLATE NOCASE, contacts.id
                LIMIT 500
                """,
                arguments: [organizationId, vaultId]
            )
            let members = try memberRows.map {
                try OrganizationWorkspaceMember(
                    contact: ContactRecord(row: $0),
                    roleLabel: $0["membershipRoleLabel"]
                )
            }
            let projects = try ProjectRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT projects.*
                FROM project_resource_references
                JOIN projects ON projects.id = project_resource_references.projectId
                WHERE project_resource_references.resourceType = 'organization'
                  AND project_resource_references.resourceId = ?
                  AND projects.vaultId = ?
                ORDER BY projects.name COLLATE NOCASE, projects.id
                LIMIT 500
                """,
                arguments: [organizationId, vaultId]
            )
            let topicRows = try Row.fetchAll(
                db,
                sql: """
                SELECT topics.*,
                       MAX(CASE WHEN refs.resourceType = 'meeting' THEN meetings.createdAt END) AS lastDiscussedAt,
                       COUNT(DISTINCT CASE WHEN refs.resourceType = 'meeting' THEN refs.resourceId END) AS meetingCount,
                       COUNT(DISTINCT CASE WHEN refs.resourceType = 'organization' THEN refs.resourceId END)
                           AS organizationCount
                FROM conversation_topics AS topics
                JOIN conversation_topic_references AS organization_ref
                  ON organization_ref.topicId = topics.id
                 AND organization_ref.resourceType = 'organization'
                 AND organization_ref.resourceId = ?
                LEFT JOIN conversation_topic_references AS refs ON refs.topicId = topics.id
                LEFT JOIN meetings
                  ON refs.resourceType = 'meeting'
                 AND meetings.id = refs.resourceId
                 AND meetings.vaultId = topics.vaultId
                WHERE topics.vaultId = ?
                GROUP BY topics.id
                ORDER BY COALESCE(lastDiscussedAt, topics.updatedAt) DESC
                LIMIT 500
                """,
                arguments: [organizationId, vaultId]
            )
            let meetings = try MeetingRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT meetings.*
                FROM organization_memberships
                JOIN meeting_participants
                  ON meeting_participants.contactId = organization_memberships.contactId
                JOIN meetings ON meetings.id = meeting_participants.meetingId
                WHERE organization_memberships.organizationId = ?
                  AND meetings.vaultId = ?
                  AND meeting_participants.responseStatus <> 'declined'
                ORDER BY meetings.createdAt DESC
                LIMIT 25
                """,
                arguments: [organizationId, vaultId]
            )
            return try OrganizationWorkspaceDetail(
                domains: domains,
                members: members,
                projects: projects,
                topics: topicRows.map(Self.topicOverview(from:)),
                recentMeetings: meetings
            )
        }
    }

    nonisolated func organizationDeletionImpact(id: UUID, vaultId: UUID) throws -> OrganizationDeletionImpact {
        try dbQueue.read { db in
            try Self.organizationDeletionImpact(id: id, vaultId: vaultId, in: db)
        }
    }

    nonisolated func organizationDeletionPreview(
        id: UUID,
        vaultId: UUID
    ) throws -> (organization: OrganizationRecord, impact: OrganizationDeletionImpact) {
        try dbQueue.read { db in
            guard let organization = try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            return try (
                organization: organization,
                impact: Self.organizationDeletionImpact(id: id, vaultId: vaultId, in: db)
            )
        }
    }

    // MARK: - Conversation topics

    nonisolated func fetchConversationTopics(vaultId: UUID) throws -> [ConversationTopicOverview] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT topics.*,
                       MAX(CASE WHEN refs.resourceType = 'meeting' THEN meetings.createdAt END) AS lastDiscussedAt,
                       COUNT(DISTINCT CASE WHEN refs.resourceType = 'meeting' THEN refs.resourceId END) AS meetingCount,
                       COUNT(DISTINCT CASE WHEN refs.resourceType = 'organization' THEN refs.resourceId END)
                           AS organizationCount
                FROM conversation_topics AS topics
                LEFT JOIN conversation_topic_references AS refs ON refs.topicId = topics.id
                LEFT JOIN meetings
                  ON refs.resourceType = 'meeting'
                 AND meetings.id = refs.resourceId
                 AND meetings.vaultId = topics.vaultId
                WHERE topics.vaultId = ?
                GROUP BY topics.id
                ORDER BY COALESCE(lastDiscussedAt, topics.updatedAt) DESC, topics.id DESC
                LIMIT 500
                """,
                arguments: [vaultId]
            )
            return try rows.map(Self.topicOverview(from:))
        }
    }

    nonisolated func fetchConversationTopic(id: UUID, vaultId: UUID) throws
        -> (ConversationTopicOverview, [ConversationTopicReferenceRecord])? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT topics.*,
                       MAX(CASE WHEN refs.resourceType = 'meeting' THEN meetings.createdAt END) AS lastDiscussedAt,
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
            let references = try ConversationTopicReferenceRecord
                .filter(Column("topicId") == id)
                .order(Column("resourceType").asc, Column("createdAt").desc)
                .fetchAll(db)
            return try (Self.topicOverview(from: row), references)
        }
    }

    nonisolated func fetchConversationTopicMeetingEvidence(
        id: UUID,
        vaultId: UUID
    ) throws -> [ConversationTopicMeetingEvidence] {
        try dbQueue.read { db in
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
                ORDER BY meetings.createdAt DESC, meetings.id
                """,
                arguments: [id, vaultId]
            ).map {
                try ConversationTopicMeetingEvidence(
                    meeting: MeetingRecord(row: $0),
                    note: $0["topicNote"]
                )
            }
        }
    }

    nonisolated func createConversationTopic(
        vaultId: UUID,
        title: String,
        currentState: String,
        references: [CustomerIntelligenceTopicReferenceInput] = [],
        now: Date = .now
    ) throws -> ConversationTopicRecord {
        try dbQueue.write { db in
            try Self.createTopic(
                id: .v7(),
                vaultId: vaultId,
                title: title,
                currentState: currentState,
                references: references,
                now: now,
                in: db
            )
        }
    }

    nonisolated func updateConversationTopic(
        id: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        title: String,
        currentState: String,
        now: Date = .now
    ) throws -> ConversationTopicRecord {
        try dbQueue.write { db in
            guard var topic = try ConversationTopicRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.topicNotFound
            }
            guard topic.revision == expectedRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard let title = Self.normalizedText(title),
                  let currentState = Self.normalizedText(currentState)
            else {
                throw CustomerIntelligenceError.invalidName
            }
            topic.title = title
            topic.currentState = currentState
            topic.revision += 1
            topic.updatedAt = now
            try topic.update(db)
            return topic
        }
    }

    func replaceConversationTopicReferences(
        topicId: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        references: [CustomerIntelligenceTopicReferenceInput],
        now: Date = .now
    ) throws {
        try dbQueue.write { db in
            guard let topic = try ConversationTopicRecord
                .filter(Column("id") == topicId && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.topicNotFound
            }
            guard topic.revision == expectedRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            try Self.replaceTopicReferences(topicId: topicId, references: references, now: now, in: db)
        }
    }

    nonisolated func topicDeletionImpact(id: UUID, vaultId: UUID) throws -> TopicDeletionImpact {
        try dbQueue.read { db in
            try Self.topicDeletionImpact(id: id, vaultId: vaultId, in: db)
        }
    }

    nonisolated func deleteConversationTopic(
        id: UUID,
        vaultId: UUID,
        expectedRevision: Int? = nil,
        expectedImpact: TopicDeletionImpact? = nil,
        now _: Date = .now
    ) throws {
        try dbQueue.write { db in
            guard let topic = try ConversationTopicRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.topicNotFound
            }
            guard expectedRevision.map({ $0 == topic.revision }) ?? true else {
                throw CustomerIntelligenceError.revisionConflict
            }
            if let expectedImpact,
               try Self.topicDeletionImpact(id: id, vaultId: vaultId, in: db) != expectedImpact {
                throw CustomerIntelligenceError.revisionConflict
            }
            _ = try ConversationTopicRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Provisional contacts

    nonisolated func createProvisionalContact(
        vaultId: UUID,
        displayName: String,
        organizationId: UUID? = nil,
        expectedOrganizationRevision: Int? = nil,
        now: Date = .now
    ) throws -> ContactRecord {
        try dbQueue.write { db in
            let contact = try Self.createProvisionalContact(
                id: .v7(),
                vaultId: vaultId,
                displayName: displayName,
                now: now,
                in: db
            )
            if let organizationId {
                guard let organization = try OrganizationRecord
                    .filter(Column("id") == organizationId && Column("vaultId") == vaultId)
                    .fetchOne(db),
                    expectedOrganizationRevision.map({ $0 == organization.revision }) ?? true
                else {
                    throw CustomerIntelligenceError.revisionConflict
                }
                try OrganizationMembershipRecord(
                    organizationId: organizationId,
                    contactId: contact.id,
                    roleLabel: nil,
                    createdAt: now
                ).insert(db)
            }
            return contact
        }
    }

    nonisolated func provisionalContactDeletionImpact(
        id: UUID,
        vaultId: UUID
    ) throws -> ProvisionalContactDeletionImpact {
        try dbQueue.read { db in
            guard let contact = try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db), contact.isProvisional
            else {
                throw CustomerIntelligenceError.provisionalContactRequired
            }
            return try Self.provisionalContactDeletionImpact(id: id, in: db)
        }
    }

    nonisolated func deleteProvisionalContact(
        id: UUID,
        vaultId: UUID,
        expectedRevision: Int? = nil,
        expectedImpact: ProvisionalContactDeletionImpact? = nil,
        now: Date = .now
    ) throws {
        try dbQueue.write { db in
            guard let contact = try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db), contact.isProvisional
            else {
                throw CustomerIntelligenceError.provisionalContactRequired
            }
            let impact = try Self.provisionalContactDeletionImpact(id: id, in: db)
            guard expectedRevision.map({ $0 == contact.revision }) ?? true,
                  expectedImpact.map({ $0 == impact }) ?? true
            else {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard impact.meetingParticipants == 0 else {
                throw CustomerIntelligenceError.provisionalContactHasParticipant
            }
            let owners = try Self.referenceOwnerIDs(
                resourceType: .contact,
                resourceIDs: [id],
                in: db
            )
            _ = try ContactRecord.deleteOne(db, key: id)
            try Self.incrementReferenceOwnerRevisions(owners, now: now, in: db)
        }
    }

    // MARK: - Contact correction and deletion

    nonisolated func resolveProvisionalContact(
        id: UUID,
        vaultId: UUID,
        email rawEmail: String,
        displayName rawDisplayName: String?,
        expectedRevision: Int,
        expectedExistingContactID: UUID?,
        expectedExistingRevision: Int?,
        now: Date = .now
    ) throws -> ContactRecord {
        try dbQueue.write { db in
            guard let email = CustomerIdentityNormalizer.email(rawEmail),
                  var provisional = try ContactRecord
                  .filter(Column("id") == id && Column("vaultId") == vaultId)
                  .fetchOne(db),
                  provisional.isProvisional
            else {
                throw CustomerIntelligenceError.provisionalContactRequired
            }
            guard provisional.revision == expectedRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            let existing = try ContactRecord
                .filter(Column("vaultId") == vaultId && Column("email") == email)
                .fetchOne(db)
            guard existing?.id == expectedExistingContactID,
                  expectedExistingContactID == nil || existing?.revision == expectedExistingRevision
            else {
                throw CustomerIntelligenceError.revisionConflict
            }
            let displayName = CustomerIdentityNormalizer.displayName(rawDisplayName)
            if displayName != provisional.displayName {
                provisional.displayName = displayName
                provisional.revision += 1
                provisional.updatedAt = now
                try provisional.update(db)
            }
            return try Self.resolveProvisionalContact(
                id: id,
                vaultId: vaultId,
                email: email,
                now: now,
                in: db
            )
        }
    }

    private nonisolated static func resolveProvisionalContact(
        id: UUID,
        vaultId: UUID,
        email rawEmail: String,
        now: Date,
        in db: Database
    ) throws -> ContactRecord {
        guard let email = CustomerIdentityNormalizer.email(rawEmail),
              var provisional = try ContactRecord
              .filter(Column("id") == id && Column("vaultId") == vaultId)
              .fetchOne(db),
              provisional.isProvisional
        else {
            throw CustomerIntelligenceError.provisionalContactRequired
        }
        guard var existing = try ContactRecord
            .filter(Column("vaultId") == vaultId && Column("email") == email)
            .fetchOne(db)
        else {
            provisional.email = email
            provisional.revision += 1
            provisional.updatedAt = now
            try provisional.update(db)
            return provisional
        }
        if existing.displayName == nil, let provisionalName = provisional.displayName {
            existing.displayName = provisionalName
            existing.revision += 1
            existing.updatedAt = now
            try existing.update(db)
        }
        try moveContactReferences(from: id, to: existing.id, now: now, in: db)
        _ = try ContactRecord.deleteOne(db, key: id)
        guard let resolved = try ContactRecord.fetchOne(db, key: existing.id) else {
            throw CustomerIntelligenceError.contactNotFound
        }
        return resolved
    }

    private nonisolated static func moveContactReferences(
        from sourceID: UUID,
        to targetID: UUID,
        now: Date,
        in db: Database
    ) throws {
        let owners = try referenceOwnerIDs(
            resourceType: .contact,
            resourceIDs: [sourceID],
            in: db
        )
        try db.execute(
            sql: CustomerIntelligenceContactReferenceMerge.sql,
            arguments: ["targetID": targetID, "sourceID": sourceID, "now": now]
        )
        try incrementReferenceOwnerRevisions(owners, now: now, in: db)
    }

    nonisolated static func referenceOwnerIDs(
        resourceType: CustomerResourceType,
        resourceIDs: [UUID],
        in db: Database
    ) throws -> (projects: [UUID], insights: [UUID]) {
        guard !resourceIDs.isEmpty else { return ([], []) }
        let placeholders = Self.placeholders(resourceIDs.count)
        return try (
            projects: UUID.fetchAll(
                db,
                sql: """
                SELECT DISTINCT projectId
                FROM project_resource_references
                WHERE resourceType = ? AND resourceId IN (\(placeholders))
                """,
                arguments: StatementArguments([resourceType.rawValue]) + StatementArguments(resourceIDs)
            ),
            insights: UUID.fetchAll(
                db,
                sql: """
                SELECT DISTINCT insightId
                FROM insight_references
                WHERE resourceType = ? AND resourceId IN (\(placeholders))
                """,
                arguments: StatementArguments([resourceType.rawValue]) + StatementArguments(resourceIDs)
            )
        )
    }

    nonisolated static func incrementReferenceOwnerRevisions(
        _ owners: (projects: [UUID], insights: [UUID]),
        now: Date,
        in db: Database
    ) throws {
        for projectID in owners.projects {
            try db.execute(
                sql: "UPDATE projects SET revision = revision + 1 WHERE id = ?",
                arguments: [projectID]
            )
        }
        for insightID in owners.insights {
            try db.execute(
                sql: "UPDATE insights SET revision = revision + 1, updatedAt = ? WHERE id = ?",
                arguments: [now, insightID]
            )
        }
    }

    private nonisolated static func provisionalContactDeletionImpact(
        id: UUID,
        in db: Database
    ) throws -> ProvisionalContactDeletionImpact {
        func count(_ table: String, where clause: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(clause)", arguments: [id]) ?? 0
        }
        return try ProvisionalContactDeletionImpact(
            memberships: count("organization_memberships", where: "contactId = ?"),
            projects: count(
                "project_resource_references",
                where: "resourceType = 'contact' AND resourceId = ?"
            ),
            insights: count("insight_references", where: "resourceType = 'contact' AND resourceId = ?"),
            topics: count(
                "conversation_topic_references",
                where: "resourceType = 'contact' AND resourceId = ?"
            ),
            meetingParticipants: count("meeting_participants", where: "contactId = ?")
        )
    }

    nonisolated static func organizationDeletionImpact(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> OrganizationDeletionImpact {
        guard try OrganizationRecord
            .filter(Column("id") == id && Column("vaultId") == vaultId)
            .fetchOne(db) != nil
        else {
            throw CustomerIntelligenceError.organizationNotFound
        }
        let row = try Row.fetchOne(
            db,
            sql: """
            WITH RECURSIVE subtree(id, depth) AS (
                SELECT id, 0 FROM organizations WHERE id = ? AND vaultId = ?
                UNION ALL
                SELECT child.id, subtree.depth + 1
                FROM organizations AS child
                JOIN subtree ON child.parentOrganizationId = subtree.id
                WHERE child.vaultId = ? AND subtree.depth < 32
            )
            SELECT
                (SELECT COUNT(*) FROM subtree) AS organizationCount,
                (SELECT COUNT(*) FROM organization_memberships
                 WHERE organizationId IN (SELECT id FROM subtree)) AS memberships,
                (SELECT COUNT(*) FROM project_resource_references
                 WHERE resourceType = 'organization'
                   AND resourceId IN (SELECT id FROM subtree)) AS projects,
                (SELECT COUNT(*) FROM conversation_topic_references
                 WHERE resourceType = 'organization'
                   AND resourceId IN (SELECT id FROM subtree)) AS topics,
                (SELECT COUNT(*) FROM insight_references
                 WHERE resourceType = 'organization'
                   AND resourceId IN (SELECT id FROM subtree)) AS insights
            """,
            arguments: [id, vaultId, vaultId]
        )
        return OrganizationDeletionImpact(
            organizationCount: row?["organizationCount"] ?? 0,
            memberships: row?["memberships"] ?? 0,
            projects: row?["projects"] ?? 0,
            topics: row?["topics"] ?? 0,
            insights: row?["insights"] ?? 0
        )
    }

    private nonisolated static func topicDeletionImpact(
        id: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> TopicDeletionImpact {
        guard try ConversationTopicRecord
            .filter(Column("id") == id && Column("vaultId") == vaultId)
            .fetchOne(db) != nil
        else {
            throw CustomerIntelligenceError.topicNotFound
        }
        return try TopicDeletionImpact(
            meetings: Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM conversation_topic_references
                WHERE topicId = ? AND resourceType = 'meeting'
                """,
                arguments: [id]
            ) ?? 0,
            relatedResources: Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM conversation_topic_references
                WHERE topicId = ? AND resourceType <> 'meeting'
                """,
                arguments: [id]
            ) ?? 0
        )
    }

    // MARK: - Helpers

    private nonisolated static func createProvisionalContact(
        id: UUID,
        vaultId: UUID,
        displayName: String,
        now: Date,
        in db: Database
    ) throws -> ContactRecord {
        guard let displayName = normalizedText(displayName) else {
            throw CustomerIntelligenceError.invalidName
        }
        let contact = ContactRecord(
            id: id,
            vaultId: vaultId,
            email: nil,
            displayName: displayName,
            revision: 1,
            createdAt: now,
            updatedAt: now
        )
        try contact.insert(db)
        return contact
    }

    private nonisolated static func createTopic(
        id: UUID,
        vaultId: UUID,
        title: String,
        currentState: String,
        references: [CustomerIntelligenceTopicReferenceInput],
        now: Date,
        in db: Database
    ) throws -> ConversationTopicRecord {
        guard let title = normalizedText(title), let currentState = normalizedText(currentState) else {
            throw CustomerIntelligenceError.invalidName
        }
        let topic = ConversationTopicRecord(
            id: id,
            vaultId: vaultId,
            title: title,
            currentState: currentState,
            revision: 1,
            createdAt: now,
            updatedAt: now
        )
        try topic.insert(db)
        try replaceTopicReferences(topicId: id, references: references, now: now, in: db)
        return try ConversationTopicRecord.fetchOne(db, key: id) ?? topic
    }

    private nonisolated static func replaceTopicReferences(
        topicId: UUID,
        references: [CustomerIntelligenceTopicReferenceInput],
        now: Date,
        in db: Database
    ) throws {
        guard references.count <= 100,
              Set(references.map { "\($0.resourceType.rawValue):\($0.resourceID)" }).count == references.count
        else {
            throw CustomerIntelligenceError.invalidName
        }
        _ = try ConversationTopicReferenceRecord
            .filter(Column("topicId") == topicId)
            .deleteAll(db)
        for reference in references {
            guard let type = ConversationTopicResourceType(rawValue: reference.resourceType.rawValue) else {
                throw CustomerIntelligenceError.invalidReference
            }
            let note = normalizedText(reference.note)
            guard type != .meeting || note != nil else {
                throw CustomerIntelligenceError.invalidName
            }
            try ConversationTopicReferenceRecord(
                topicId: topicId,
                resourceType: type,
                resourceId: reference.resourceID,
                note: type == .meeting ? note : nil,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }
    }

    private nonisolated static func topicOverview(from row: Row) throws -> ConversationTopicOverview {
        try ConversationTopicOverview(
            topic: ConversationTopicRecord(row: row),
            lastDiscussedAt: row["lastDiscussedAt"],
            meetingCount: row["meetingCount"],
            organizationCount: row["organizationCount"]
        )
    }

    private nonisolated static func organizationWorkspaceNodes(
        where predicate: String,
        arguments: StatementArguments,
        limit: Int,
        offset: Int,
        in db: Database
    ) throws -> [OrganizationWorkspaceNode] {
        var arguments = arguments
        arguments += [limit, offset]
        return try Row.fetchAll(
            db,
            sql: """
            SELECT organizations.*,
                   (SELECT COUNT(*) FROM organizations AS child
                    WHERE child.parentOrganizationId = organizations.id) AS childCount
            FROM organizations
            WHERE \(predicate)
            ORDER BY organizations.name COLLATE NOCASE, organizations.id
            LIMIT ? OFFSET ?
            """,
            arguments: arguments
        ).map {
            try OrganizationWorkspaceNode(
                organization: OrganizationRecord(row: $0),
                childCount: $0["childCount"]
            )
        }
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
