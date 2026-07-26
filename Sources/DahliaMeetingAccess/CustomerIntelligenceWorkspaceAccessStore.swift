import DahliaRuntimeSupport
import Foundation
import GRDB

public extension MeetingAccessStore {
    private static let maximumOrganizationChartNodeCount = 500

    func queryOrganizationChart(_ query: OrganizationChartAccessQuery) throws -> OrganizationChartAccessResult {
        guard (0 ... 32).contains(query.maximumDepth), (1 ... 100).contains(query.childrenPerNode) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            guard let root = try Row.fetchOne(
                db,
                sql: """
                SELECT nodeKind, parentOrganizationId
                FROM organizations WHERE id = ? AND vaultId = ? LIMIT 1
                """,
                arguments: [query.rootOrganizationID, vaultID]
            ) else {
                throw MeetingAccessError.organizationNotFound
            }
            guard (root["nodeKind"] as String) == "organization",
                  (root["parentOrganizationId"] as UUID?) == nil
            else {
                throw MeetingAccessError.invalidCustomerIntelligenceData
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH RECURSIVE hierarchy(id, parentOrganizationId, depth) AS (
                    SELECT id, parentOrganizationId, 0
                    FROM organizations
                    WHERE id = ? AND vaultId = ?
                    UNION ALL
                    SELECT child.id, child.parentOrganizationId, hierarchy.depth + 1
                    FROM organizations AS child
                    JOIN hierarchy ON child.parentOrganizationId = hierarchy.id
                    WHERE child.vaultId = ?
                      AND hierarchy.depth < ?
                      AND (
                          SELECT COUNT(*) FROM organizations AS sibling
                          WHERE sibling.parentOrganizationId = child.parentOrganizationId
                            AND sibling.vaultId = child.vaultId
                            AND (
                                sibling.name COLLATE NOCASE < child.name COLLATE NOCASE
                                OR (sibling.name = child.name COLLATE NOCASE AND sibling.id <= child.id)
                            )
                      ) <= ?
                    LIMIT ?
                )
                SELECT organizations.*, hierarchy.depth,
                       (SELECT COUNT(*) FROM organization_memberships
                        WHERE organizationId = organizations.id) AS memberCount,
                       (SELECT COUNT(*) FROM project_resource_references
                        WHERE resourceType = 'organization' AND resourceId = organizations.id) AS projectCount,
                       (SELECT COUNT(*) FROM conversation_topic_references
                        WHERE resourceType = 'organization' AND resourceId = organizations.id) AS topicCount,
                       (SELECT COUNT(DISTINCT participants.meetingId)
                        FROM organization_memberships AS memberships
                        JOIN meeting_participants AS participants ON participants.contactId = memberships.contactId
                        WHERE memberships.organizationId = organizations.id
                          AND participants.responseStatus <> 'declined') AS meetingCount,
                       (SELECT MAX(meetings.createdAt)
                        FROM organization_memberships AS memberships
                        JOIN meeting_participants AS participants ON participants.contactId = memberships.contactId
                        JOIN meetings ON meetings.id = participants.meetingId
                        WHERE memberships.organizationId = organizations.id
                          AND participants.responseStatus <> 'declined') AS lastInteractionAt,
                       (SELECT COUNT(*) FROM organizations AS child
                        WHERE child.parentOrganizationId = organizations.id) AS childCount
                FROM hierarchy
                JOIN organizations ON organizations.id = hierarchy.id
                ORDER BY hierarchy.depth, organizations.name COLLATE NOCASE, organizations.id
                """,
                arguments: [
                    query.rootOrganizationID,
                    vaultID,
                    vaultID,
                    query.maximumDepth,
                    query.childrenPerNode,
                    Self.maximumOrganizationChartNodeCount + 1,
                ]
            )
            let nodesTruncated = rows.count > Self.maximumOrganizationChartNodeCount
            let nodes = try rows.prefix(Self.maximumOrganizationChartNodeCount).map {
                row -> OrganizationChartAccessNode in
                guard let kind = OrganizationAccessNodeKind(rawValue: row["nodeKind"]) else {
                    throw MeetingAccessError.invalidCustomerIntelligenceData
                }
                let childCount: Int = row["childCount"]
                return OrganizationChartAccessNode(
                    id: row["id"],
                    parentOrganizationID: row["parentOrganizationId"],
                    nodeKind: kind,
                    name: row["name"],
                    depth: row["depth"],
                    revision: row["revision"],
                    memberCount: row["memberCount"],
                    projectCount: row["projectCount"],
                    topicCount: row["topicCount"],
                    meetingCount: row["meetingCount"],
                    lastInteractionAt: row["lastInteractionAt"],
                    childCount: childCount,
                    childrenTruncated: childCount > query.childrenPerNode
                        || ((row["depth"] as Int) == query.maximumDepth && childCount > 0)
                )
            }
            return OrganizationChartAccessResult(
                vault: vault,
                rootOrganizationID: query.rootOrganizationID,
                nodes: nodes,
                nodesTruncated: nodesTruncated
            )
        }
    }

    func queryConversationTopics(
        _ query: ConversationTopicAccessQuery = ConversationTopicAccessQuery()
    ) throws -> ConversationTopicAccessPage {
        try validateCustomerLimit(query.limit)
        let scope = customerCursorScope("conversation_topics", components: [
            query.organizationID?.uuidString,
            query.includeDescendants.description,
            query.projectID?.uuidString,
        ])
        let cursor = try query.cursor.map {
            try CustomerDateCursor.decode($0, vaultID: vaultID, scope: scope)
        }
        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            var predicates = ["topics.vaultId = ?"]
            var arguments: StatementArguments = [vaultID]
            if let organizationID = query.organizationID {
                if query.includeDescendants {
                    predicates.append("""
                    EXISTS (
                        SELECT 1 FROM conversation_topic_references AS organization_refs
                        WHERE organization_refs.topicId = topics.id
                          AND organization_refs.resourceType = 'organization'
                          AND organization_refs.resourceId IN (
                              WITH RECURSIVE subtree(id, depth) AS (
                                  SELECT id, 0 FROM organizations WHERE id = ? AND vaultId = ?
                                  UNION ALL
                                  SELECT child.id, subtree.depth + 1
                                  FROM organizations AS child
                                  JOIN subtree ON child.parentOrganizationId = subtree.id
                                  WHERE child.vaultId = ? AND subtree.depth < 32
                              )
                              SELECT id FROM subtree
                          )
                    )
                    """)
                    arguments += [organizationID, vaultID, vaultID]
                } else {
                    predicates.append("""
                    EXISTS (
                        SELECT 1 FROM conversation_topic_references AS organization_refs
                        WHERE organization_refs.topicId = topics.id
                          AND organization_refs.resourceType = 'organization'
                          AND organization_refs.resourceId = ?
                    )
                    """)
                    arguments += [organizationID]
                }
            }
            if let projectID = query.projectID {
                predicates.append("""
                EXISTS (
                    SELECT 1 FROM conversation_topic_references AS project_refs
                    WHERE project_refs.topicId = topics.id
                      AND project_refs.resourceType = 'project'
                      AND project_refs.resourceId = ?
                )
                """)
                arguments += [projectID]
            }
            if let cursor {
                predicates.append("(topics.updatedAt < ? OR (topics.updatedAt = ? AND topics.id < ?))")
                arguments += [cursor.date, cursor.date, cursor.id]
            }
            let rows = try topicRows(
                predicates: predicates,
                arguments: arguments,
                limit: query.limit + 1,
                in: db
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let topics = pageRows.map(Self.topicMetadata(from:))
            let nextCursor = hasMore ? topics.last.map {
                CustomerDateCursor(vaultID: vaultID, scope: scope, date: $0.updatedAt, id: $0.id).encoded()
            } : nil
            return ConversationTopicAccessPage(vault: vault, topics: topics, nextCursor: nextCursor)
        }
    }

    func conversationTopic(id: UUID) throws -> ConversationTopicAccessDetail {
        try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            guard let row = try topicRows(
                predicates: ["topics.id = ?", "topics.vaultId = ?"],
                arguments: [id, vaultID],
                limit: 1,
                in: db
            ).first else {
                throw MeetingAccessError.invalidCustomerIntelligenceData
            }
            let referenceRows = try Row.fetchAll(
                db,
                sql: """
                SELECT refs.*,
                       CASE refs.resourceType
                           WHEN 'organization' THEN (SELECT name FROM organizations WHERE id = refs.resourceId)
                           WHEN 'contact' THEN (SELECT COALESCE(displayName, email) FROM contacts WHERE id = refs.resourceId)
                           WHEN 'project' THEN (SELECT name FROM projects WHERE id = refs.resourceId)
                           WHEN 'meeting' THEN (SELECT name FROM meetings WHERE id = refs.resourceId)
                       END AS resourceName
                FROM conversation_topic_references AS refs
                WHERE refs.topicId = ?
                ORDER BY CASE refs.resourceType WHEN 'meeting' THEN 0 ELSE 1 END,
                         refs.createdAt DESC, refs.resourceId
                LIMIT ?
                """,
                arguments: [id, Self.customerNestedLimit + 1]
            )
            guard referenceRows.count <= Self.customerNestedLimit else {
                throw MeetingAccessError.invalidCustomerIntelligenceData
            }
            let references = try referenceRows.map { referenceRow -> ConversationTopicReferenceAccessMetadata in
                guard let type = CustomerIntelligenceResourceKind(rawValue: referenceRow["resourceType"]) else {
                    throw MeetingAccessError.invalidCustomerIntelligenceData
                }
                return ConversationTopicReferenceAccessMetadata(
                    resourceType: type,
                    resourceID: referenceRow["resourceId"],
                    resourceName: referenceRow["resourceName"],
                    note: referenceRow["note"],
                    createdAt: referenceRow["createdAt"]
                )
            }
            return try ConversationTopicAccessDetail(
                vault: vault,
                topic: Self.topicMetadata(from: row),
                references: references,
                referencesExpectation: Self.topicReferenceExpectation(topicID: id, in: db)
            )
        }
    }

    func queryCustomerIntelligenceProposals(
        _ query: CustomerIntelligenceProposalAccessQuery = CustomerIntelligenceProposalAccessQuery()
    ) throws -> CustomerIntelligenceProposalAccessPage {
        try validateCustomerLimit(query.limit)
        let scope = customerCursorScope("customer_intelligence_proposals", components: [query.status?.rawValue])
        let cursor = try query.cursor.map {
            try CustomerDateCursor.decode($0, vaultID: vaultID, scope: scope)
        }
        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            var predicates = ["vaultId = ?"]
            var arguments: StatementArguments = [vaultID]
            if let status = query.status {
                predicates.append("status = ?")
                arguments += [status.rawValue]
            }
            if let cursor {
                predicates.append("(createdAt < ? OR (createdAt = ? AND id < ?))")
                arguments += [cursor.date, cursor.date, cursor.id]
            }
            arguments += [query.limit + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM customer_intelligence_proposals
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY createdAt DESC, id DESC LIMIT ?
                """,
                arguments: arguments
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let proposalIDs: [UUID] = pageRows.map { $0["id"] }
            let placeholders = Array(repeating: "?", count: proposalIDs.count).joined(separator: ",")
            let evidenceRows = proposalIDs.isEmpty ? [] : try Row.fetchAll(
                db,
                sql: """
                SELECT proposalId, resourceType, resourceId, note
                FROM customer_intelligence_proposal_evidence
                WHERE proposalId IN (\(placeholders))
                ORDER BY createdAt, resourceType, resourceId
                """,
                arguments: StatementArguments(proposalIDs)
            )
            let dependencyRows = proposalIDs.isEmpty ? [] : try Row.fetchAll(
                db,
                sql: """
                SELECT proposalId, requiredProposalId
                FROM customer_intelligence_proposal_dependencies
                WHERE proposalId IN (\(placeholders))
                ORDER BY createdAt, requiredProposalId
                """,
                arguments: StatementArguments(proposalIDs)
            )
            let evidenceByProposal = Dictionary(grouping: evidenceRows) { row -> UUID in row["proposalId"] }
            let dependenciesByProposal = Dictionary(grouping: dependencyRows) { row -> UUID in row["proposalId"] }
            let proposals = try pageRows.map {
                let id: UUID = $0["id"]
                return try proposalMetadata(
                    from: $0,
                    evidenceRows: evidenceByProposal[id, default: []],
                    dependencyRows: dependenciesByProposal[id, default: []]
                )
            }
            let nextCursor = hasMore ? proposals.last.map {
                CustomerDateCursor(vaultID: vaultID, scope: scope, date: $0.createdAt, id: $0.id).encoded()
            } : nil
            return CustomerIntelligenceProposalAccessPage(
                vault: vault,
                proposals: proposals,
                nextCursor: nextCursor
            )
        }
    }
}

private extension MeetingAccessStore {
    func topicRows(
        predicates: [String],
        arguments: StatementArguments,
        limit: Int,
        in db: Database
    ) throws -> [Row] {
        var arguments = arguments
        arguments += [limit]
        return try Row.fetchAll(
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
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY topics.id
            ORDER BY topics.updatedAt DESC, topics.id DESC
            LIMIT ?
            """,
            arguments: arguments
        )
    }

    static func topicMetadata(from row: Row) -> ConversationTopicAccessMetadata {
        ConversationTopicAccessMetadata(
            id: row["id"],
            title: row["title"],
            currentState: row["currentState"],
            revision: row["revision"],
            lastDiscussedAt: row["lastDiscussedAt"],
            meetingCount: row["meetingCount"],
            organizationCount: row["organizationCount"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    static func topicReferenceExpectation(topicID: UUID, in db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT resourceType, resourceId, note
            FROM conversation_topic_references
            WHERE topicId = ?
            ORDER BY resourceType, resourceId
            """,
            arguments: [topicID]
        )
        return try CustomerIntelligenceTopicReferenceExpectation.encode(rows.map {
            CustomerIntelligenceTopicReferenceExpectation.Item(
                resourceType: $0["resourceType"],
                resourceID: $0["resourceId"],
                note: $0["note"]
            )
        })
    }

    func proposalMetadata(
        from row: Row,
        evidenceRows: [Row],
        dependencyRows: [Row]
    ) throws -> CustomerIntelligenceProposalAccessMetadata {
        let payloadJSON: String = row["payloadJSON"]
        guard let operation = CustomerIntelligenceProposalOperationType(rawValue: row["operationType"]),
              let status = CustomerIntelligenceProposalAccessStatus(rawValue: row["status"]),
              let payload = try? JSONDecoder().decode(
                  CustomerIntelligenceProposalPayload.self,
                  from: Data(payloadJSON.utf8)
              )
        else {
            throw MeetingAccessError.invalidCustomerIntelligenceData
        }
        let proposalID: UUID = row["id"]
        let evidence = try evidenceRows.map { evidenceRow -> CustomerIntelligenceProposalEvidenceAccessMetadata in
            guard let type = CustomerIntelligenceResourceKind(rawValue: evidenceRow["resourceType"]) else {
                throw MeetingAccessError.invalidCustomerIntelligenceData
            }
            return CustomerIntelligenceProposalEvidenceAccessMetadata(
                resourceType: type,
                resourceID: evidenceRow["resourceId"],
                note: evidenceRow["note"]
            )
        }
        return CustomerIntelligenceProposalAccessMetadata(
            id: proposalID,
            operationType: operation,
            payload: payload,
            status: status,
            staleReason: row["staleReason"],
            revision: row["revision"],
            evidence: evidence,
            dependencies: dependencyRows.map { $0["requiredProposalId"] },
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }
}
