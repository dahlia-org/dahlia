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
                LIMIT ?
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
                    description: row["description"],
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
                throw MeetingAccessError.conversationTopicNotFound
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
            let referencesTruncated = referenceRows.count > Self.customerNestedLimit
            let references = try referenceRows.prefix(Self.customerNestedLimit).map {
                referenceRow -> ConversationTopicReferenceAccessMetadata in
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
            return ConversationTopicAccessDetail(
                vault: vault,
                topic: Self.topicMetadata(from: row),
                references: references,
                referencesTruncated: referencesTruncated
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

}
