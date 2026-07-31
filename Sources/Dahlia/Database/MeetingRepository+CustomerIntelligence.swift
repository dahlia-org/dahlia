import DahliaRuntimeSupport
import Foundation
import GRDB

struct ContactOverview: Equatable {
    let contact: ContactRecord
    let meetingCount: Int
    let lastInteractionAt: Date?
}

extension MeetingRepository {

    // MARK: - Contacts

    nonisolated func fetchContacts(vaultId: UUID) throws -> [ContactRecord] {
        try dbQueue.read { db in
            try ContactRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("displayName").asc, Column("email").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    func fetchContact(id: UUID, vaultId: UUID) throws -> ContactRecord? {
        try dbQueue.read { db in
            try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
        }
    }

    func fetchContactOverview(id: UUID, vaultId: UUID) throws -> ContactOverview? {
        try dbQueue.read { db in
            guard let contact = try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                return nil
            }
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(meetings.id) AS meetingCount, MAX(meetings.createdAt) AS lastInteractionAt
                FROM meeting_participants
                JOIN meetings ON meetings.id = meeting_participants.meetingId
                WHERE meeting_participants.contactId = ?
                  AND meetings.vaultId = ?
                  AND meeting_participants.responseStatus <> 'declined'
                """,
                arguments: [id, vaultId]
            )
            return ContactOverview(
                contact: contact,
                meetingCount: row?["meetingCount"] ?? 0,
                lastInteractionAt: row?["lastInteractionAt"]
            )
        }
    }

    nonisolated func upsertContact(
        vaultId: UUID,
        email: String,
        displayName: String?,
        now: Date = .now
    ) throws -> ContactRecord {
        try dbQueue.write { db in
            try CustomerIntelligencePersistence.upsertContact(
                vaultId: vaultId,
                email: email,
                displayName: displayName,
                now: now,
                in: db
            )
        }
    }

    nonisolated func updateContactDisplayName(
        id: UUID,
        vaultId: UUID,
        displayName: String?,
        expectedRevision: Int? = nil,
        now: Date = .now
    ) throws -> ContactRecord {
        try dbQueue.write { db in
            guard var contact = try ContactRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.contactNotFound
            }
            if let expectedRevision, contact.revision != expectedRevision {
                throw CustomerIntelligenceError.revisionConflict
            }
            contact.displayName = CustomerIdentityNormalizer.displayName(displayName)
            contact.revision += 1
            contact.updatedAt = now
            try contact.update(db)
            return contact
        }
    }

    func deleteContact(id: UUID, vaultId: UUID) throws {
        try deleteProvisionalContact(id: id, vaultId: vaultId)
    }

    // MARK: - Organizations

    nonisolated func fetchOrganizations(vaultId: UUID) throws -> [OrganizationRecord] {
        try dbQueue.read { db in
            try OrganizationRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("name").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    nonisolated func fetchOrganization(id: UUID, vaultId: UUID) throws -> OrganizationRecord? {
        try dbQueue.read { db in
            try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
        }
    }

    nonisolated func createOrganization(
        vaultId: UUID,
        parentOrganizationId: UUID?,
        nodeKind: OrganizationNodeKind,
        name: String,
        description: String = "",
        now: Date = .now
    ) throws -> OrganizationRecord {
        try dbQueue.write { db in
            guard try VaultRecord.fetchOne(db, key: vaultId) != nil else {
                throw CustomerIntelligenceError.vaultNotFound
            }
            guard let name = CustomerIdentityNormalizer.organizationName(name) else {
                throw CustomerIntelligenceError.invalidName
            }
            let organization = OrganizationRecord(
                id: .v7(),
                vaultId: vaultId,
                parentOrganizationId: parentOrganizationId,
                nodeKind: nodeKind,
                name: name,
                description: description,
                revision: 1,
                createdAt: now,
                updatedAt: now
            )
            do {
                try organization.insert(db)
            } catch {
                throw Self.organizationWriteError(from: error) ?? error
            }
            return organization
        }
    }

    nonisolated func updateOrganizationName(
        id: UUID,
        vaultId: UUID,
        name: String,
        expectedRevision: Int? = nil,
        now: Date = .now
    ) throws -> OrganizationRecord {
        try dbQueue.write { db in
            guard var organization = try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            if let expectedRevision, organization.revision != expectedRevision {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard let name = CustomerIdentityNormalizer.organizationName(name) else {
                throw CustomerIntelligenceError.invalidName
            }
            organization.name = name
            organization.revision += 1
            organization.updatedAt = now
            try organization.update(db)
            return organization
        }
    }

    nonisolated func updateOrganization(
        id: UUID,
        vaultId: UUID,
        name: String,
        parentOrganizationId: UUID?,
        description: String? = nil,
        expectedRevision: Int,
        now: Date = .now
    ) throws -> OrganizationRecord {
        try dbQueue.write { db in
            guard var organization = try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            guard organization.revision == expectedRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard let name = CustomerIdentityNormalizer.organizationName(name) else {
                throw CustomerIntelligenceError.invalidName
            }
            organization.name = name
            organization.parentOrganizationId = parentOrganizationId
            if let description {
                organization.description = description
            }
            organization.revision += 1
            organization.updatedAt = now
            do {
                try organization.update(db)
            } catch {
                throw Self.organizationWriteError(from: error) ?? error
            }
            return organization
        }
    }

    nonisolated func moveOrganization(
        id: UUID,
        vaultId: UUID,
        parentOrganizationId: UUID?,
        expectedRevision: Int? = nil,
        now: Date = .now
    ) throws -> OrganizationRecord {
        try dbQueue.write { db in
            guard var organization = try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            if let expectedRevision, organization.revision != expectedRevision {
                throw CustomerIntelligenceError.revisionConflict
            }
            organization.parentOrganizationId = parentOrganizationId
            organization.revision += 1
            organization.updatedAt = now
            do {
                try organization.update(db)
            } catch {
                throw Self.organizationWriteError(from: error) ?? error
            }
            return organization
        }
    }

    nonisolated func deleteOrganization(
        id: UUID,
        vaultId: UUID,
        expectedRevision: Int? = nil,
        expectedImpact: OrganizationDeletionImpact? = nil,
        now: Date = .now
    ) throws {
        try dbQueue.write { db in
            guard let organization = try OrganizationRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            guard expectedRevision.map({ $0 == organization.revision }) ?? true else {
                throw CustomerIntelligenceError.revisionConflict
            }
            if let expectedImpact,
               try Self.organizationDeletionImpact(id: id, vaultId: vaultId, in: db) != expectedImpact {
                throw CustomerIntelligenceError.revisionConflict
            }
            let subtreeIDs = try UUID.fetchAll(
                db,
                sql: """
                WITH RECURSIVE subtree(id, depth) AS (
                    SELECT id, 0
                    FROM organizations
                    WHERE id = ? AND vaultId = ?
                    UNION ALL
                    SELECT child.id, subtree.depth + 1
                    FROM organizations AS child
                    JOIN subtree ON child.parentOrganizationId = subtree.id
                    WHERE child.vaultId = ? AND subtree.depth < ?
                )
                SELECT id
                FROM subtree
                ORDER BY depth DESC
                """,
                arguments: [id, vaultId, vaultId, CustomerIntelligenceMigration.maximumOrganizationDepth]
            )
            let owners = try Self.referenceOwnerIDs(
                resourceType: .organization,
                resourceIDs: subtreeIDs,
                in: db
            )
            for subtreeID in subtreeIDs {
                _ = try OrganizationRecord.deleteOne(db, key: subtreeID)
            }
            try Self.incrementReferenceOwnerRevisions(owners, now: now, in: db)
        }
    }

    nonisolated func fetchOrganizationDomains(organizationId: UUID, vaultId: UUID) throws -> [OrganizationDomainRecord] {
        try dbQueue.read { db in
            try OrganizationDomainRecord
                .filter(Column("organizationId") == organizationId && Column("vaultId") == vaultId)
                .order(Column("isPrimary").desc, Column("domainName").asc)
                .fetchAll(db)
        }
    }

    nonisolated func organizationDomainAssignmentPlan(
        targetOrganizationId: UUID,
        vaultId: UUID,
        domainName rawDomainName: String,
        expectedTargetRevision: Int
    ) throws -> OrganizationDomainAssignmentPlan {
        guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
            throw CustomerIntelligenceError.invalidDomain
        }
        return try dbQueue.read { db in
            guard let target = try OrganizationRecord
                .filter(Column("id") == targetOrganizationId && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            guard target.revision == expectedTargetRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard target.isRootOrganization else {
                throw CustomerIntelligenceError.invalidOrganizationMerge
            }
            let domains = try OrganizationDomainRecord
                .filter(Column("vaultId") == vaultId && Column("domainName") == domainName)
                .fetchAll(db)
            guard !domains.isEmpty else {
                return .unassigned
            }
            guard !domains.contains(where: { $0.organizationId == targetOrganizationId }) else {
                return .alreadyAssigned
            }
            guard domains.count == 1, let domain = domains.first else {
                let ownerIDs = domains.map(\.organizationId)
                let rootOwnerCount = try OrganizationRecord
                    .filter(
                        ownerIDs.contains(Column("id"))
                            && Column("vaultId") == vaultId
                            && Column("nodeKind") == OrganizationNodeKind.organization
                            && Column("parentOrganizationId") == nil
                    )
                    .fetchCount(db)
                guard rootOwnerCount == ownerIDs.count else {
                    throw CustomerIntelligenceError.invalidOrganizationMerge
                }
                return .shared
            }
            guard let source = try OrganizationRecord
                .filter(Column("id") == domain.organizationId && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            guard source.isRootOrganization else {
                throw CustomerIntelligenceError.invalidOrganizationMerge
            }
            return try .merge(OrganizationMergePreview(
                domainName: domainName,
                source: source,
                target: target,
                impact: Self.organizationMergeImpact(sourceOrganizationId: source.id, in: db)
            ))
        }
    }

    nonisolated func addOrganizationDomain(
        organizationId: UUID,
        vaultId: UUID,
        domainName rawDomainName: String,
        expectedOrganizationRevision: Int? = nil,
        observedAt: Date = .now
    ) throws -> OrganizationDomainRecord {
        try dbQueue.write { db in
            guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
                throw CustomerIntelligenceError.invalidDomain
            }
            guard let organization = try OrganizationRecord
                .filter(Column("id") == organizationId && Column("vaultId") == vaultId)
                .fetchOne(db),
                organization.isRootOrganization
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            if let expectedOrganizationRevision, organization.revision != expectedOrganizationRevision {
                throw CustomerIntelligenceError.revisionConflict
            }
            if var existing = try OrganizationDomainRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("domainName") == domainName
                        && Column("organizationId") == organizationId
                )
                .fetchOne(db) {
                let firstObservedAt = min(existing.firstObservedAt, observedAt)
                let lastObservedAt = max(existing.lastObservedAt, observedAt)
                if firstObservedAt != existing.firstObservedAt || lastObservedAt != existing.lastObservedAt {
                    existing.firstObservedAt = firstObservedAt
                    existing.lastObservedAt = lastObservedAt
                    try existing.update(db)
                }
                return existing
            }
            var domain = OrganizationDomainRecord(
                vaultId: vaultId,
                domainName: domainName,
                organizationId: organizationId,
                isPrimary: false,
                firstObservedAt: observedAt,
                lastObservedAt: observedAt
            )
            try domain.insert(db)
            domain = try OrganizationDomainRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("domainName") == domainName
                        && Column("organizationId") == organizationId
                )
                .fetchOne(db) ?? domain
            return domain
        }
    }

    nonisolated func setPrimaryOrganizationDomain(
        organizationId: UUID,
        vaultId: UUID,
        domainName rawDomainName: String
    ) throws {
        try dbQueue.write { db in
            guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName),
                  try OrganizationDomainRecord
                  .filter(
                      Column("organizationId") == organizationId
                          && Column("vaultId") == vaultId
                          && Column("domainName") == domainName
                  )
                  .fetchOne(db) != nil
            else {
                throw CustomerIntelligenceError.invalidDomain
            }
            _ = try OrganizationDomainRecord
                .filter(Column("organizationId") == organizationId)
                .updateAll(db, Column("isPrimary").set(to: false))
            _ = try OrganizationDomainRecord
                .filter(
                    Column("organizationId") == organizationId
                        && Column("vaultId") == vaultId
                        && Column("domainName") == domainName
                )
                .updateAll(db, Column("isPrimary").set(to: true))
        }
    }

    nonisolated func removeOrganizationDomain(
        organizationId: UUID,
        vaultId: UUID,
        domainName rawDomainName: String
    ) throws {
        guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
            throw CustomerIntelligenceError.invalidDomain
        }
        try dbQueue.write { db in
            _ = try OrganizationDomainRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("domainName") == domainName
                        && Column("organizationId") == organizationId
                )
                .deleteAll(db)
        }
    }

    // swiftlint:disable:next function_body_length
    nonisolated func mergeOrganization(
        sourceOrganizationId: UUID,
        targetOrganizationId: UUID,
        vaultId: UUID,
        expectedSourceDomainName rawExpectedSourceDomainName: String,
        expectedSourceRevision: Int,
        expectedTargetRevision: Int,
        expectedImpact: OrganizationMergeImpact,
        now: Date = .now
    ) throws -> OrganizationRecord {
        guard let expectedSourceDomainName = CustomerIdentityNormalizer.domainName(rawExpectedSourceDomainName) else {
            throw CustomerIntelligenceError.invalidDomain
        }
        return try dbQueue.write { db in
            let organizations = try Self.validatedMergeOrganizations(
                sourceOrganizationId: sourceOrganizationId,
                targetOrganizationId: targetOrganizationId,
                vaultId: vaultId,
                in: db
            )
            guard organizations.source.revision == expectedSourceRevision,
                  organizations.target.revision == expectedTargetRevision,
                  try Self.organizationMergeImpact(sourceOrganizationId: sourceOrganizationId, in: db) == expectedImpact
            else {
                throw CustomerIntelligenceError.revisionConflict
            }
            guard try OrganizationDomainRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("domainName") == expectedSourceDomainName
                        && Column("organizationId") == sourceOrganizationId
                )
                .fetchOne(db) != nil
            else {
                throw CustomerIntelligenceError.revisionConflict
            }

            let referenceOwners = try Self.referenceOwnerIDs(
                resourceType: .organization,
                resourceIDs: [sourceOrganizationId],
                in: db
            )
            let sourceDomains = try OrganizationDomainRecord
                .filter(Column("organizationId") == sourceOrganizationId)
                .order(Column("firstObservedAt").asc, Column("domainName").asc)
                .fetchAll(db)
            let targetHasPrimaryDomain = try OrganizationDomainRecord
                .filter(Column("organizationId") == targetOrganizationId && Column("isPrimary") == true)
                .fetchOne(db) != nil
            let domainsToMove: [OrganizationDomainRecord] = if targetHasPrimaryDomain {
                sourceDomains
            } else if let sourcePrimaryDomain = sourceDomains.first(where: \.isPrimary) {
                [sourcePrimaryDomain] + sourceDomains.filter { !$0.isPrimary }
            } else {
                sourceDomains
            }

            try db.execute(
                sql: """
                UPDATE organizations
                SET parentOrganizationId = ?, revision = revision + 1, updatedAt = ?
                WHERE parentOrganizationId = ? AND vaultId = ?
                """,
                arguments: [targetOrganizationId, now, sourceOrganizationId, vaultId]
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO organization_memberships
                    (organizationId, contactId, roleLabel, createdAt)
                SELECT ?, contactId, roleLabel, createdAt
                FROM organization_memberships
                WHERE organizationId = ?;
                DELETE FROM organization_memberships WHERE organizationId = ?;
                """,
                arguments: [targetOrganizationId, sourceOrganizationId, sourceOrganizationId]
            )

            _ = try OrganizationDomainRecord
                .filter(Column("organizationId") == sourceOrganizationId)
                .deleteAll(db)
            for domain in domainsToMove {
                let shouldBePrimary = !targetHasPrimaryDomain && domain.isPrimary
                if var existing = try OrganizationDomainRecord
                    .filter(
                        Column("vaultId") == domain.vaultId
                            && Column("domainName") == domain.domainName
                            && Column("organizationId") == targetOrganizationId
                    )
                    .fetchOne(db) {
                    existing.firstObservedAt = min(existing.firstObservedAt, domain.firstObservedAt)
                    existing.lastObservedAt = max(existing.lastObservedAt, domain.lastObservedAt)
                    existing.isPrimary = existing.isPrimary || shouldBePrimary
                    try existing.update(db)
                } else {
                    try OrganizationDomainRecord(
                        vaultId: domain.vaultId,
                        domainName: domain.domainName,
                        organizationId: targetOrganizationId,
                        isPrimary: shouldBePrimary,
                        firstObservedAt: domain.firstObservedAt,
                        lastObservedAt: domain.lastObservedAt
                    ).insert(db)
                }
            }

            try db.execute(
                sql: """
                UPDATE OR IGNORE project_resource_references
                SET resourceId = :targetID, updatedAt = :now
                WHERE resourceType = 'organization' AND resourceId = :sourceID;
                DELETE FROM project_resource_references
                WHERE resourceType = 'organization' AND resourceId = :sourceID;

                INSERT OR IGNORE INTO insight_references
                    (insightId, resourceType, resourceId, referenceRole, createdAt)
                SELECT insightId, resourceType, :targetID, referenceRole, createdAt
                FROM insight_references
                WHERE resourceType = 'organization' AND resourceId = :sourceID;
                DELETE FROM insight_references
                WHERE resourceType = 'organization' AND resourceId = :sourceID;

                INSERT OR IGNORE INTO conversation_topic_references
                    (topicId, resourceType, resourceId, note, createdAt, updatedAt)
                SELECT topicId, resourceType, :targetID, note, createdAt, :now
                FROM conversation_topic_references
                WHERE resourceType = 'organization' AND resourceId = :sourceID;
                DELETE FROM conversation_topic_references
                WHERE resourceType = 'organization' AND resourceId = :sourceID;
                """,
                arguments: [
                    "targetID": targetOrganizationId,
                    "sourceID": sourceOrganizationId,
                    "now": now,
                ]
            )
            try Self.incrementReferenceOwnerRevisions(referenceOwners, now: now, in: db)

            try db.execute(
                sql: """
                UPDATE organizations
                SET revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [now, targetOrganizationId, vaultId]
            )
            _ = try OrganizationRecord.deleteOne(db, key: sourceOrganizationId)
            guard let target = try OrganizationRecord.fetchOne(db, key: targetOrganizationId) else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            return target
        }
    }

    private nonisolated static func validatedMergeOrganizations(
        sourceOrganizationId: UUID,
        targetOrganizationId: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> (source: OrganizationRecord, target: OrganizationRecord) {
        guard sourceOrganizationId != targetOrganizationId else {
            throw CustomerIntelligenceError.invalidOrganizationMerge
        }
        guard let source = try OrganizationRecord
            .filter(Column("id") == sourceOrganizationId && Column("vaultId") == vaultId)
            .fetchOne(db),
            let target = try OrganizationRecord
            .filter(Column("id") == targetOrganizationId && Column("vaultId") == vaultId)
            .fetchOne(db)
        else {
            throw CustomerIntelligenceError.organizationNotFound
        }
        guard source.isRootOrganization, target.isRootOrganization else {
            throw CustomerIntelligenceError.invalidOrganizationMerge
        }
        return (source, target)
    }

    private nonisolated static func organizationMergeImpact(
        sourceOrganizationId: UUID,
        in db: Database
    ) throws -> OrganizationMergeImpact {
        let row = try Row.fetchOne(
            db,
            sql: """
            WITH RECURSIVE descendants(id) AS (
                SELECT id FROM organizations WHERE parentOrganizationId = ?
                UNION ALL
                SELECT child.id
                FROM organizations AS child
                JOIN descendants ON child.parentOrganizationId = descendants.id
            )
            SELECT
                (SELECT COUNT(*) FROM organization_domains
                 WHERE organizationId = ?) AS domains,
                (SELECT COUNT(*) FROM organization_memberships
                 WHERE organizationId = ?) AS memberships,
                (SELECT COUNT(*) FROM descendants) AS descendantOrganizations,
                (SELECT COUNT(DISTINCT projectId) FROM project_resource_references
                 WHERE resourceType = 'organization' AND resourceId = ?) AS projects,
                (SELECT COUNT(DISTINCT topicId) FROM conversation_topic_references
                 WHERE resourceType = 'organization' AND resourceId = ?) AS topics,
                (SELECT COUNT(DISTINCT insightId) FROM insight_references
                 WHERE resourceType = 'organization' AND resourceId = ?) AS insights
            """,
            arguments: [
                sourceOrganizationId,
                sourceOrganizationId,
                sourceOrganizationId,
                sourceOrganizationId,
                sourceOrganizationId,
                sourceOrganizationId,
            ]
        )
        return OrganizationMergeImpact(
            domains: row?["domains"] ?? 0,
            memberships: row?["memberships"] ?? 0,
            descendantOrganizations: row?["descendantOrganizations"] ?? 0,
            projects: row?["projects"] ?? 0,
            topics: row?["topics"] ?? 0,
            insights: row?["insights"] ?? 0
        )
    }

    nonisolated func addOrganizationMembership(
        organizationId: UUID,
        contactId: UUID,
        roleLabel: String? = nil,
        expectedOrganizationRevision: Int? = nil,
        createdAt: Date = .now
    ) throws -> OrganizationMembershipRecord {
        try dbQueue.write { db in
            if let expectedOrganizationRevision {
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT revision FROM organizations WHERE id = ?",
                    arguments: [organizationId]
                ) == expectedOrganizationRevision else {
                    throw CustomerIntelligenceError.revisionConflict
                }
            }
            let normalizedRole = CustomerIdentityNormalizer.displayName(roleLabel)
            if var existing = try OrganizationMembershipRecord
                .filter(Column("organizationId") == organizationId && Column("contactId") == contactId)
                .fetchOne(db) {
                if existing.roleLabel != normalizedRole {
                    existing.roleLabel = normalizedRole
                    try existing.update(db)
                }
                return existing
            }
            let membership = OrganizationMembershipRecord(
                organizationId: organizationId,
                contactId: contactId,
                roleLabel: normalizedRole,
                createdAt: createdAt
            )
            try membership.insert(db)
            return membership
        }
    }

    nonisolated func removeOrganizationMembership(
        organizationId: UUID,
        contactId: UUID,
        expectedOrganizationRevision: Int? = nil
    ) throws {
        try dbQueue.write { db in
            if let expectedOrganizationRevision {
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT revision FROM organizations WHERE id = ?",
                    arguments: [organizationId]
                ) == expectedOrganizationRevision else {
                    throw CustomerIntelligenceError.revisionConflict
                }
            }
            _ = try OrganizationMembershipRecord
                .filter(Column("organizationId") == organizationId && Column("contactId") == contactId)
                .deleteAll(db)
        }
    }

    // MARK: - Project resources

    func fetchProjectResourceReferences(projectId: UUID) throws -> [ProjectResourceReferenceRecord] {
        try dbQueue.read { db in
            try ProjectResourceReferenceRecord
                .filter(Column("projectId") == projectId)
                .order(Column("resourceType").asc, Column("relationLabel").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    func addProjectResourceReference(
        projectId: UUID,
        resourceType: CustomerResourceType,
        resourceId: UUID,
        relationLabel: String? = nil,
        now: Date = .now
    ) throws -> ProjectResourceReferenceRecord {
        guard resourceType == .organization || resourceType == .contact else {
            throw CustomerIntelligenceError.unsupportedProjectResource
        }
        return try dbQueue.write { db in
            let normalizedLabel = CustomerIdentityNormalizer.relationLabel(relationLabel)
            if let existing = try ProjectResourceReferenceRecord
                .filter(
                    Column("projectId") == projectId
                        && Column("resourceType") == resourceType
                        && Column("resourceId") == resourceId
                        && Column("relationLabel") == normalizedLabel
                )
                .fetchOne(db) {
                return existing
            }
            let reference = ProjectResourceReferenceRecord(
                id: .v7(),
                projectId: projectId,
                resourceType: resourceType,
                resourceId: resourceId,
                relationLabel: normalizedLabel,
                createdAt: now,
                updatedAt: now
            )
            try reference.insert(db)
            try db.execute(
                sql: "UPDATE projects SET revision = revision + 1 WHERE id = ?",
                arguments: [projectId]
            )
            return reference
        }
    }

    func deleteProjectResourceReference(id: UUID) throws {
        try dbQueue.write { db in
            guard let reference = try ProjectResourceReferenceRecord.fetchOne(db, key: id) else {
                return
            }
            guard try ProjectResourceReferenceRecord.deleteOne(db, key: id) else {
                return
            }
            try db.execute(
                sql: "UPDATE projects SET revision = revision + 1 WHERE id = ?",
                arguments: [reference.projectId]
            )
        }
    }

    // MARK: - Insights

    func createInsight(
        vaultId: UUID,
        content: String,
        isAccepted: Bool = false,
        metadataJSON: String = "{}",
        now: Date = .now
    ) throws -> InsightRecord {
        try dbQueue.write { db in
            guard let content = CustomerIdentityNormalizer.organizationName(content) else {
                throw CustomerIntelligenceError.invalidName
            }
            let metadataJSON = try Self.validatedJSONObject(metadataJSON)
            let insight = InsightRecord(
                id: .v7(),
                vaultId: vaultId,
                content: content,
                isAccepted: isAccepted,
                metadataJSON: metadataJSON,
                revision: 1,
                createdAt: now,
                updatedAt: now
            )
            try insight.insert(db)
            return insight
        }
    }

    nonisolated func setInsightAccepted(
        id: UUID,
        vaultId: UUID,
        expectedRevision: Int,
        isAccepted: Bool,
        metadataJSON: String? = nil,
        now: Date = .now
    ) throws -> InsightRecord {
        try dbQueue.write { db in
            guard var insight = try InsightRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.insightNotFound
            }
            guard insight.revision == expectedRevision else {
                throw CustomerIntelligenceError.revisionConflict
            }
            insight.isAccepted = isAccepted
            if let metadataJSON {
                insight.metadataJSON = try Self.validatedJSONObject(metadataJSON)
            }
            insight.revision += 1
            insight.updatedAt = now
            try insight.update(db)
            return insight
        }
    }

    func addInsightReference(
        insightId: UUID,
        resourceType: CustomerResourceType,
        resourceId: UUID,
        role: InsightReferenceRole,
        createdAt: Date = .now
    ) throws -> InsightReferenceRecord {
        try dbQueue.write { db in
            if let existing = try InsightReferenceRecord
                .filter(
                    Column("insightId") == insightId
                        && Column("resourceType") == resourceType
                        && Column("resourceId") == resourceId
                        && Column("referenceRole") == role
                )
                .fetchOne(db) {
                return existing
            }
            let reference = InsightReferenceRecord(
                insightId: insightId,
                resourceType: resourceType,
                resourceId: resourceId,
                referenceRole: role,
                createdAt: createdAt
            )
            try reference.insert(db)
            try db.execute(
                sql: "UPDATE insights SET revision = revision + 1, updatedAt = ? WHERE id = ?",
                arguments: [createdAt, insightId]
            )
            return reference
        }
    }

    private nonisolated static func organizationWriteError(from error: Error) -> CustomerIntelligenceError? {
        guard let message = (error as? DatabaseError)?.message else { return nil }
        switch message {
        case "organization hierarchy cannot contain a cycle":
            return .organizationCycle
        case "organization hierarchy exceeds maximum depth":
            return .organizationHierarchyTooDeep
        case "organization root must have organization kind",
             "organization parent must exist in the same vault",
             "an organization cannot be placed under a unit":
            return .invalidOrganizationParent
        default:
            return nil
        }
    }

    private nonisolated static func validatedJSONObject(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
            throw CustomerIntelligenceError.invalidJSON
        }
        return trimmed
    }
}
