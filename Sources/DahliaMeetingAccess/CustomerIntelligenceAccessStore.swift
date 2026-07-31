import Foundation
import GRDB

public extension MeetingAccessStore {
    func queryOrganizations(
        _ query: OrganizationAccessQuery = OrganizationAccessQuery()
    ) throws -> OrganizationAccessPage {
        try validateCustomerLimit(query.limit)
        let searchValue = customerSearchValue(query.query)
        let scope = customerCursorScope("organizations", components: [
            searchValue,
            query.nodeKind?.rawValue,
            query.parentOrganizationID?.uuidString,
            query.rootsOnly.description,
        ])
        let cursor = try query.cursor.map {
            try CustomerTextCursor.decode($0, vaultID: vaultID, scope: scope)
        }

        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            var predicates = ["organizations.vaultId = ?"]
            var arguments: StatementArguments = [vaultID]
            if let nodeKind = query.nodeKind {
                predicates.append("organizations.nodeKind = ?")
                arguments += [nodeKind.rawValue]
            }
            if query.rootsOnly {
                predicates.append("organizations.parentOrganizationId IS NULL")
            } else if let parentOrganizationID = query.parentOrganizationID {
                predicates.append("organizations.parentOrganizationId = ?")
                arguments += [parentOrganizationID]
            }
            if let value = searchValue {
                let pattern = "%\(escapedLikePattern(value))%"
                predicates.append("""
                (
                    organizations.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR organizations.description LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR EXISTS (
                        SELECT 1
                        FROM organization_domains
                        WHERE organization_domains.organizationId = organizations.id
                          AND organization_domains.domainName LIKE ? ESCAPE '\\' COLLATE NOCASE
                    )
                )
                """)
                arguments += [pattern, pattern, pattern]
            }
            if let cursor {
                predicates.append("""
                (
                    organizations.name COLLATE NOCASE > ? COLLATE NOCASE
                    OR (
                        organizations.name = ? COLLATE NOCASE
                        AND organizations.id > ?
                    )
                )
                """)
                arguments += [cursor.sortKey, cursor.sortKey, cursor.id]
            }
            let rows = try organizationRows(
                predicates: predicates,
                arguments: arguments,
                limit: query.limit + 1,
                in: db
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let organizations = try pageRows.map(Self.organizationMetadata(from:))
            let nextCursor = hasMore ? organizations.last.map {
                CustomerTextCursor(
                    vaultID: vaultID,
                    scope: scope,
                    sortKey: $0.name,
                    id: $0.id
                ).encoded()
            } : nil
            return OrganizationAccessPage(
                vault: vault,
                organizations: organizations,
                nextCursor: nextCursor
            )
        }
    }

    func organization(id: UUID) throws -> OrganizationAccessDetail {
        try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            guard let row = try organizationRow(id: id, in: db) else {
                throw MeetingAccessError.organizationNotFound
            }
            let organization = try Self.organizationMetadata(from: row)
            let domainRows = try Row.fetchAll(
                db,
                sql: """
                SELECT domainName, isPrimary, firstObservedAt, lastObservedAt
                FROM organization_domains
                WHERE organizationId = ? AND vaultId = ?
                ORDER BY isPrimary DESC, domainName COLLATE NOCASE ASC
                LIMIT ?
                """,
                arguments: [id, vaultID, Self.customerNestedLimit + 1]
            )
            let memberRows = try Row.fetchAll(
                db,
                sql: """
                SELECT contacts.id, contacts.email, contacts.displayName, contacts.revision, memberships.roleLabel
                FROM organization_memberships AS memberships
                JOIN contacts ON contacts.id = memberships.contactId
                WHERE memberships.organizationId = ? AND contacts.vaultId = ?
                ORDER BY COALESCE(contacts.displayName, contacts.email) COLLATE NOCASE ASC, contacts.id ASC
                LIMIT ?
                """,
                arguments: [id, vaultID, Self.customerNestedLimit + 1]
            )
            let projectResources = try projectResources(
                resourceType: .organization,
                resourceID: id,
                in: db
            )
            return OrganizationAccessDetail(
                vault: vault,
                organization: organization,
                domains: domainRows.prefix(Self.customerNestedLimit).map {
                    OrganizationDomainAccessMetadata(
                        domainName: $0["domainName"],
                        isPrimary: $0["isPrimary"],
                        firstObservedAt: $0["firstObservedAt"],
                        lastObservedAt: $0["lastObservedAt"]
                    )
                },
                domainsTruncated: domainRows.count > Self.customerNestedLimit,
                members: memberRows.prefix(Self.customerNestedLimit).map {
                    OrganizationMemberAccessMetadata(
                        contactID: $0["id"],
                        email: $0["email"],
                        displayName: $0["displayName"],
                        isProvisional: ($0["email"] as String?) == nil,
                        revision: $0["revision"],
                        roleLabel: $0["roleLabel"]
                    )
                },
                membersTruncated: memberRows.count > Self.customerNestedLimit,
                projectResources: projectResources.resources,
                projectResourcesTruncated: projectResources.truncated
            )
        }
    }

    func queryContacts(_ query: ContactAccessQuery = ContactAccessQuery()) throws -> ContactAccessPage {
        try validateCustomerLimit(query.limit)
        let searchValue = customerSearchValue(query.query)
        let scope = customerCursorScope("contacts", components: [
            searchValue,
            query.organizationID?.uuidString,
        ])
        let cursor = try query.cursor.map {
            try CustomerTextCursor.decode($0, vaultID: vaultID, scope: scope)
        }

        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            var predicates = ["contacts.vaultId = ?"]
            var arguments: StatementArguments = [vaultID]
            if let organizationID = query.organizationID {
                predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM organization_memberships
                    JOIN organizations ON organizations.id = organization_memberships.organizationId
                    WHERE organization_memberships.contactId = contacts.id
                      AND organizations.id = ?
                      AND organizations.vaultId = contacts.vaultId
                )
                """)
                arguments += [organizationID]
            }
            if let value = searchValue {
                let pattern = "%\(escapedLikePattern(value))%"
                predicates.append("""
                (
                    contacts.email LIKE ? ESCAPE '\\' COLLATE NOCASE
                    OR contacts.displayName LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                """)
                arguments += [pattern, pattern]
            }
            if let cursor {
                predicates.append("""
                (
                    COALESCE(contacts.displayName, contacts.email) COLLATE NOCASE > ? COLLATE NOCASE
                    OR (
                        COALESCE(contacts.displayName, contacts.email) = ? COLLATE NOCASE
                        AND contacts.id > ?
                    )
                )
                """)
                arguments += [cursor.sortKey, cursor.sortKey, cursor.id]
            }
            let rows = try contactRows(
                predicates: predicates,
                arguments: arguments,
                limit: query.limit + 1,
                in: db
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let contacts = pageRows.map(Self.contactMetadata(from:))
            let nextCursor = hasMore ? pageRows.last.map { row in
                CustomerTextCursor(
                    vaultID: vaultID,
                    scope: scope,
                    sortKey: row["sortKey"],
                    id: row["id"]
                ).encoded()
            } : nil
            return ContactAccessPage(vault: vault, contacts: contacts, nextCursor: nextCursor)
        }
    }

    func contact(id: UUID) throws -> ContactAccessDetail {
        try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            let rows = try contactRows(
                predicates: ["contacts.vaultId = ?", "contacts.id = ?"],
                arguments: [vaultID, id],
                limit: 1,
                in: db
            )
            guard let row = rows.first else {
                throw MeetingAccessError.contactNotFound
            }
            let membershipRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    organizations.id,
                    organizations.name,
                    organizations.nodeKind,
                    memberships.roleLabel
                FROM organization_memberships AS memberships
                JOIN organizations ON organizations.id = memberships.organizationId
                WHERE memberships.contactId = ? AND organizations.vaultId = ?
                ORDER BY organizations.name COLLATE NOCASE ASC, organizations.id ASC
                LIMIT ?
                """,
                arguments: [id, vaultID, Self.customerNestedLimit + 1]
            )
            let meetingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    meetings.id,
                    meetings.name,
                    meetings.createdAt,
                    participants.role,
                    participants.responseStatus,
                    participants.source
                FROM meeting_participants AS participants
                JOIN meetings ON meetings.id = participants.meetingId
                WHERE participants.contactId = ? AND meetings.vaultId = ?
                  AND participants.responseStatus <> 'declined'
                ORDER BY meetings.createdAt DESC, meetings.id DESC
                LIMIT 25
                """,
                arguments: [id, vaultID]
            )
            let projectResources = try projectResources(resourceType: .contact, resourceID: id, in: db)
            return try ContactAccessDetail(
                vault: vault,
                contact: Self.contactMetadata(from: row),
                memberships: membershipRows.prefix(Self.customerNestedLimit).map {
                    guard let nodeKind = OrganizationAccessNodeKind(rawValue: $0["nodeKind"]) else {
                        throw MeetingAccessError.invalidCustomerIntelligenceData
                    }
                    return ContactMembershipAccessMetadata(
                        organizationID: $0["id"],
                        organizationName: $0["name"],
                        nodeKind: nodeKind,
                        roleLabel: $0["roleLabel"]
                    )
                },
                membershipsTruncated: membershipRows.count > Self.customerNestedLimit,
                recentMeetings: meetingRows.map {
                    ContactMeetingAccessMetadata(
                        meetingID: $0["id"],
                        meetingName: $0["name"],
                        createdAt: $0["createdAt"],
                        role: $0["role"],
                        responseStatus: $0["responseStatus"],
                        source: $0["source"]
                    )
                },
                projectResources: projectResources.resources,
                projectResourcesTruncated: projectResources.truncated
            )
        }
    }

    func queryProjectResources(_ query: ProjectResourceAccessQuery) throws -> ProjectResourceAccessPage {
        try validateCustomerLimit(query.limit)
        guard query.resourceType != .project, query.resourceType != .meeting else {
            throw MeetingAccessError.invalidResourceFilter
        }
        let scope = "project-resources:\(query.projectID.uuidString):\(query.resourceType?.rawValue ?? "*")"
        let cursor = try query.cursor.map {
            try CustomerDateCursor.decode($0, vaultID: vaultID, scope: scope)
        }

        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ? AND vaultId = ?)",
                arguments: [query.projectID, vaultID]
            ) == true else {
                throw MeetingAccessError.projectNotFound
            }
            var predicates = ["resource_refs.projectId = ?", "projects.vaultId = ?"]
            var arguments: StatementArguments = [query.projectID, vaultID]
            if let resourceType = query.resourceType {
                predicates.append("resource_refs.resourceType = ?")
                arguments += [resourceType.rawValue]
            }
            if let cursor {
                predicates.append("""
                (
                    resource_refs.createdAt < ?
                    OR (resource_refs.createdAt = ? AND resource_refs.id < ?)
                )
                """)
                arguments += [cursor.date, cursor.date, cursor.id]
            }
            let rows = try projectResourceRows(
                predicates: predicates,
                arguments: arguments,
                limit: query.limit + 1,
                in: db
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let resources = try pageRows.map(Self.projectResourceMetadata(from:))
            let nextCursor = hasMore ? resources.last.map {
                CustomerDateCursor(
                    vaultID: vaultID,
                    scope: scope,
                    date: $0.createdAt,
                    id: $0.id
                ).encoded()
            } : nil
            return ProjectResourceAccessPage(vault: vault, resources: resources, nextCursor: nextCursor)
        }
    }

    func queryInsights(_ query: InsightAccessQuery = InsightAccessQuery()) throws -> InsightAccessPage {
        try validateCustomerLimit(query.limit)
        try validateResourcePair(type: query.resourceType, id: query.resourceID)
        let scope = customerCursorScope("insights", components: [
            query.isAccepted.map(String.init),
            query.resourceType?.rawValue,
            query.resourceID?.uuidString,
        ])
        let cursor = try query.cursor.map {
            try CustomerDateCursor.decode($0, vaultID: vaultID, scope: scope)
        }

        return try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            var predicates = ["insights.vaultId = ?"]
            var arguments: StatementArguments = [vaultID]
            if let isAccepted = query.isAccepted {
                predicates.append("insights.isAccepted = ?")
                arguments += [isAccepted]
            }
            if let resourceType = query.resourceType, let resourceID = query.resourceID {
                predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM insight_references
                    WHERE insight_references.insightId = insights.id
                      AND insight_references.resourceType = ?
                      AND insight_references.resourceId = ?
                )
                """)
                arguments += [resourceType.rawValue, resourceID]
            }
            if let cursor {
                predicates.append("""
                (
                    insights.createdAt < ?
                    OR (insights.createdAt = ? AND insights.id < ?)
                )
                """)
                arguments += [cursor.date, cursor.date, cursor.id]
            }
            arguments += [query.limit + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM insights
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY createdAt DESC, id DESC
                LIMIT ?
                """,
                arguments: arguments
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let referenceRows = try insightReferenceRows(
                insightIDs: pageRows.map { $0["id"] },
                in: db
            )
            let insights = try pageRows.map { row in
                let id: UUID = row["id"]
                return try insightMetadata(
                    from: row,
                    referenceRows: referenceRows[id, default: []]
                )
            }
            let nextCursor = hasMore ? insights.last.map {
                CustomerDateCursor(
                    vaultID: vaultID,
                    scope: scope,
                    date: $0.createdAt,
                    id: $0.id
                ).encoded()
            } : nil
            return InsightAccessPage(vault: vault, insights: insights, nextCursor: nextCursor)
        }
    }

    func insight(id: UUID) throws -> InsightAccessDetail {
        try database.read { db in
            let vault = try fetchCustomerIntelligenceVault(in: db)
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM insights WHERE id = ? AND vaultId = ?",
                arguments: [id, vaultID]
            ) else {
                throw MeetingAccessError.insightNotFound
            }
            let references = try insightReferenceRows(insightIDs: [id], in: db)
            return try InsightAccessDetail(
                vault: vault,
                insight: insightMetadata(from: row, referenceRows: references[id, default: []])
            )
        }
    }

}

extension MeetingAccessStore {
    static let customerNestedLimit = 100

    func fetchCustomerIntelligenceVault(in db: Database) throws -> ScopedVault {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?)",
            arguments: ["v33_sharedOrganizationDomains"]
        ) == true else {
            throw MeetingAccessError.databaseUpgradeRequired
        }
        return try fetchVault(in: db)
    }

    func validateCustomerLimit(_ limit: Int) throws {
        guard (1 ... 100).contains(limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
    }

    func validateResourcePair(type: CustomerResourceAccessType?, id: UUID?) throws {
        guard (type == nil) == (id == nil) else {
            throw MeetingAccessError.invalidResourceFilter
        }
    }

    func organizationRow(id: UUID, in db: Database) throws -> Row? {
        try organizationRows(
            predicates: ["organizations.id = ?", "organizations.vaultId = ?"],
            arguments: [id, vaultID],
            limit: 1,
            in: db
        ).first
    }

    func organizationRows(
        predicates: [String],
        arguments: StatementArguments,
        limit: Int,
        in db: Database
    ) throws -> [Row] {
        var queryArguments: StatementArguments = [vaultID]
        queryArguments += arguments
        queryArguments += [limit]
        return try Row.fetchAll(
            db,
            sql: """
            WITH child_counts AS (
                SELECT parentOrganizationId AS organizationId, COUNT(*) AS childCount
                FROM organizations
                WHERE vaultId = ? AND parentOrganizationId IS NOT NULL
                GROUP BY parentOrganizationId
            )
            SELECT
                organizations.*,
                (
                    SELECT domainName
                    FROM organization_domains
                    WHERE organizationId = organizations.id AND isPrimary = 1
                ) AS primaryDomain,
                (
                    SELECT COUNT(*)
                    FROM organization_domains
                    WHERE organizationId = organizations.id
                ) AS domainCount,
                (
                    SELECT COUNT(*)
                    FROM organization_memberships
                    WHERE organizationId = organizations.id
                ) AS memberCount,
                COALESCE(child_counts.childCount, 0) AS childCount
            FROM organizations
            LEFT JOIN child_counts ON child_counts.organizationId = organizations.id
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY organizations.name COLLATE NOCASE ASC, organizations.id ASC
            LIMIT ?
            """,
            arguments: queryArguments
        )
    }

    static func organizationMetadata(from row: Row) throws -> OrganizationAccessMetadata {
        guard let nodeKind = OrganizationAccessNodeKind(rawValue: row["nodeKind"]) else {
            throw MeetingAccessError.invalidCustomerIntelligenceData
        }
        return OrganizationAccessMetadata(
            id: row["id"],
            parentOrganizationID: row["parentOrganizationId"],
            nodeKind: nodeKind,
            name: row["name"],
            description: row["description"],
            primaryDomain: row["primaryDomain"],
            domainCount: row["domainCount"],
            memberCount: row["memberCount"],
            childCount: row["childCount"],
            revision: row["revision"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    func contactRows(
        predicates: [String],
        arguments: StatementArguments,
        limit: Int,
        in db: Database
    ) throws -> [Row] {
        var queryArguments = arguments
        queryArguments += [limit]
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                contacts.*,
                COALESCE(contacts.displayName, contacts.email) AS sortKey,
                (
                    SELECT COUNT(*)
                    FROM organization_memberships
                    WHERE organization_memberships.contactId = contacts.id
                ) AS organizationCount,
                COUNT(interaction_meetings.id) AS meetingCount,
                MAX(interaction_meetings.createdAt) AS lastInteractionAt
            FROM contacts
            LEFT JOIN meeting_participants AS interaction_participants
              ON interaction_participants.contactId = contacts.id
             AND interaction_participants.responseStatus <> 'declined'
            LEFT JOIN meetings AS interaction_meetings
              ON interaction_meetings.id = interaction_participants.meetingId
             AND interaction_meetings.vaultId = contacts.vaultId
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY contacts.id
            ORDER BY sortKey COLLATE NOCASE ASC, contacts.id ASC
            LIMIT ?
            """,
            arguments: queryArguments
        )
    }

    static func contactMetadata(from row: Row) -> ContactAccessMetadata {
        ContactAccessMetadata(
            id: row["id"],
            email: row["email"],
            displayName: row["displayName"],
            isProvisional: (row["email"] as String?) == nil,
            revision: row["revision"],
            organizationCount: row["organizationCount"],
            meetingCount: row["meetingCount"],
            lastInteractionAt: row["lastInteractionAt"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    func projectResources(
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        in db: Database
    ) throws -> (resources: [ProjectResourceAccessMetadata], truncated: Bool) {
        let rows = try projectResourceRows(
            predicates: [
                "resource_refs.resourceType = ?",
                "resource_refs.resourceId = ?",
                "projects.vaultId = ?",
            ],
            arguments: [resourceType.rawValue, resourceID, vaultID],
            limit: Self.customerNestedLimit + 1,
            in: db
        )
        return try (
            rows.prefix(Self.customerNestedLimit).map(Self.projectResourceMetadata(from:)),
            rows.count > Self.customerNestedLimit
        )
    }

    func projectResourceRows(
        predicates: [String],
        arguments: StatementArguments,
        limit: Int?,
        in db: Database
    ) throws -> [Row] {
        var arguments = arguments
        let limitClause: String
        if let limit {
            arguments += [limit]
            limitClause = "LIMIT ?"
        } else {
            limitClause = ""
        }
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                resource_refs.*,
                projects.name AS projectName,
                CASE resource_refs.resourceType
                    WHEN 'organization' THEN (
                        SELECT name
                        FROM organizations
                        WHERE organizations.id = resource_refs.resourceId
                          AND organizations.vaultId = projects.vaultId
                    )
                    WHEN 'contact' THEN (
                        SELECT COALESCE(displayName, email)
                        FROM contacts
                        WHERE contacts.id = resource_refs.resourceId
                          AND contacts.vaultId = projects.vaultId
                    )
                END AS resourceName
            FROM project_resource_references AS resource_refs
            JOIN projects ON projects.id = resource_refs.projectId
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY resource_refs.createdAt DESC, resource_refs.id DESC
            \(limitClause)
            """,
            arguments: arguments
        )
    }

    static func projectResourceMetadata(from row: Row) throws -> ProjectResourceAccessMetadata {
        guard let resourceType = CustomerResourceAccessType(rawValue: row["resourceType"]) else {
            throw MeetingAccessError.invalidCustomerIntelligenceData
        }
        return ProjectResourceAccessMetadata(
            id: row["id"],
            projectID: row["projectId"],
            projectName: row["projectName"],
            resourceType: resourceType,
            resourceID: row["resourceId"],
            resourceName: row["resourceName"],
            relationLabel: row["relationLabel"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    func insightMetadata(from row: Row, referenceRows: [Row]) throws -> InsightAccessMetadata {
        let decodedMetadata = decodeJSONValue(row["metadataJSON"])
        let metadata: JSONValue = if let decodedMetadata, case .object = decodedMetadata {
            decodedMetadata
        } else {
            .object([:])
        }
        let id: UUID = row["id"]
        let references = try referenceRows.prefix(Self.customerNestedLimit).map { referenceRow in
            guard let resourceType = CustomerResourceAccessType(rawValue: referenceRow["resourceType"]),
                  let role = InsightAccessReferenceRole(rawValue: referenceRow["referenceRole"])
            else {
                throw MeetingAccessError.invalidCustomerIntelligenceData
            }
            let resourceID: UUID = referenceRow["resourceId"]
            return InsightReferenceAccessMetadata(
                resourceType: resourceType,
                resourceID: resourceID,
                resourceName: referenceRow["resourceName"],
                referenceRole: role,
                createdAt: referenceRow["createdAt"]
            )
        }
        return try InsightAccessMetadata(
            id: id,
            content: row["content"],
            isAccepted: row["isAccepted"],
            metadata: metadata,
            revision: row["revision"],
            references: references,
            referencesTruncated: referenceRows.count > Self.customerNestedLimit,
            referencesExpectation: Self.insightReferencesExpectation(referenceRows),
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"]
        )
    }

    static func insightReferencesExpectation(_ rows: [Row]) throws -> String {
        let ordered = rows.sorted {
            let lhs = (
                $0["resourceType"] as String,
                ($0["resourceId"] as UUID).uuidString,
                $0["referenceRole"] as String
            )
            let rhs = (
                $1["resourceType"] as String,
                ($1["resourceId"] as UUID).uuidString,
                $1["referenceRole"] as String
            )
            return lhs < rhs
        }
        let items = ordered.map { row in
            [
                "resource_type": row["resourceType"] as String,
                "resource_id": (row["resourceId"] as UUID).uuidString.lowercased(),
                "reference_role": row["referenceRole"] as String,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func insightReferenceRows(
        insightIDs: [UUID],
        in db: Database
    ) throws -> [UUID: [Row]] {
        guard !insightIDs.isEmpty else { return [:] }
        var arguments: StatementArguments = [vaultID]
        for id in insightIDs {
            arguments += [id]
        }
        arguments += [Self.customerNestedLimit + 1]
        let placeholders = Array(repeating: "?", count: insightIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
            WITH ranked_references AS (
                SELECT
                    reference.insightId,
                    reference.resourceType,
                    reference.resourceId,
                    reference.referenceRole,
                    reference.createdAt,
                    CASE reference.resourceType
                        WHEN 'organization' THEN (
                            SELECT name
                            FROM organizations
                            WHERE organizations.id = reference.resourceId
                              AND organizations.vaultId = insights.vaultId
                        )
                        WHEN 'contact' THEN (
                            SELECT COALESCE(displayName, email)
                            FROM contacts
                            WHERE contacts.id = reference.resourceId
                              AND contacts.vaultId = insights.vaultId
                        )
                        WHEN 'project' THEN (
                            SELECT name
                            FROM projects
                            WHERE projects.id = reference.resourceId
                              AND projects.vaultId = insights.vaultId
                        )
                        WHEN 'meeting' THEN (
                            SELECT name
                            FROM meetings
                            WHERE meetings.id = reference.resourceId
                              AND meetings.vaultId = insights.vaultId
                        )
                    END AS resourceName,
                    ROW_NUMBER() OVER (
                        PARTITION BY reference.insightId
                        ORDER BY reference.referenceRole, reference.resourceType, reference.resourceId
                    ) AS position
                FROM insight_references AS reference
                JOIN insights ON insights.id = reference.insightId
                WHERE insights.vaultId = ?
                  AND reference.insightId IN (\(placeholders))
            )
            SELECT *
            FROM ranked_references
            WHERE position <= ?
            ORDER BY insightId, position
            """,
            arguments: arguments
        )
        return Dictionary(grouping: rows) { row -> UUID in row["insightId"] }
    }

    func decodeJSONValue(_ value: String) -> JSONValue? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func customerSearchValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func customerCursorScope(_ name: String, components: [String?]) -> String {
        guard let data = try? JSONEncoder().encode(components) else { return name }
        return "\(name):\(data.base64EncodedString())"
    }
}
