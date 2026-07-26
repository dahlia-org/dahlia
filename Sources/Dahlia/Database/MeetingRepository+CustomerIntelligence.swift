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

    func fetchContacts(vaultId: UUID) throws -> [ContactRecord] {
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

    func upsertContact(
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
                throw CustomerIntelligenceError.proposalConflict
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
                throw CustomerIntelligenceError.proposalConflict
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
                throw CustomerIntelligenceError.proposalConflict
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
                throw CustomerIntelligenceError.proposalConflict
            }
            if let expectedImpact,
               try Self.organizationDeletionImpact(id: id, vaultId: vaultId, in: db) != expectedImpact {
                throw CustomerIntelligenceError.proposalConflict
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
            try Self.markProposalsStale(
                vaultId: vaultId,
                referencing: Set(subtreeIDs),
                reason: "organizationDeleted",
                now: now,
                in: db
            )
            for subtreeID in subtreeIDs {
                _ = try OrganizationRecord.deleteOne(db, key: subtreeID)
            }
        }
    }

    func fetchOrganizationDomains(organizationId: UUID, vaultId: UUID) throws -> [OrganizationDomainRecord] {
        try dbQueue.read { db in
            try OrganizationDomainRecord
                .filter(Column("organizationId") == organizationId && Column("vaultId") == vaultId)
                .order(Column("isPrimary").desc, Column("domainName").asc)
                .fetchAll(db)
        }
    }

    func addOrganizationDomain(
        organizationId: UUID,
        vaultId: UUID,
        domainName rawDomainName: String,
        observedAt: Date = .now
    ) throws -> OrganizationDomainRecord {
        try dbQueue.write { db in
            guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
                throw CustomerIntelligenceError.invalidDomain
            }
            guard let organization = try OrganizationRecord
                .filter(Column("id") == organizationId && Column("vaultId") == vaultId)
                .fetchOne(db),
                organization.nodeKind == .organization
            else {
                throw CustomerIntelligenceError.organizationNotFound
            }
            if var existing = try OrganizationDomainRecord
                .filter(Column("vaultId") == vaultId && Column("domainName") == domainName)
                .fetchOne(db) {
                guard existing.organizationId == organizationId else {
                    throw CustomerIntelligenceError.domainAlreadyAssigned
                }
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
                .filter(Column("vaultId") == vaultId && Column("domainName") == domainName)
                .fetchOne(db) ?? domain
            return domain
        }
    }

    func setPrimaryOrganizationDomain(
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

    func removeOrganizationDomain(vaultId: UUID, domainName rawDomainName: String) throws {
        guard let domainName = CustomerIdentityNormalizer.domainName(rawDomainName) else {
            throw CustomerIntelligenceError.invalidDomain
        }
        try dbQueue.write { db in
            _ = try OrganizationDomainRecord
                .filter(Column("vaultId") == vaultId && Column("domainName") == domainName)
                .deleteAll(db)
        }
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
                    throw CustomerIntelligenceError.proposalConflict
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
                    throw CustomerIntelligenceError.proposalConflict
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
            return reference
        }
    }

    func deleteProjectResourceReference(id: UUID) throws {
        try dbQueue.write { db in
            _ = try ProjectResourceReferenceRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Insights

    func createInsight(
        vaultId: UUID,
        content: String,
        reviewState: InsightReviewState = .proposed,
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
                reviewState: reviewState,
                metadataJSON: metadataJSON,
                createdAt: now,
                updatedAt: now
            )
            try insight.insert(db)
            return insight
        }
    }

    func setInsightReviewState(
        id: UUID,
        vaultId: UUID,
        reviewState: InsightReviewState,
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
            insight.reviewState = reviewState
            if let metadataJSON {
                insight.metadataJSON = try Self.validatedJSONObject(metadataJSON)
            }
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
            return reference
        }
    }

    // MARK: - Glossary

    func createGlossaryTerm(
        vaultId: UUID,
        term: String,
        definition: String,
        aliases: [String] = [],
        now: Date = .now
    ) throws -> GlossaryTermRecord {
        try dbQueue.write { db in
            guard let term = CustomerIdentityNormalizer.organizationName(term) else {
                throw CustomerIntelligenceError.invalidName
            }
            guard let definition = CustomerIdentityNormalizer.organizationName(definition) else {
                throw CustomerIntelligenceError.invalidDefinition
            }
            let aliases = aliases.compactMap(CustomerIdentityNormalizer.organizationName)
            let aliasesData = try JSONEncoder().encode(aliases)
            guard let aliasesJSON = String(bytes: aliasesData, encoding: .utf8) else {
                throw CustomerIntelligenceError.invalidJSON
            }
            let glossaryTerm = GlossaryTermRecord(
                id: .v7(),
                vaultId: vaultId,
                term: term,
                definition: definition,
                aliasesJSON: aliasesJSON,
                createdAt: now,
                updatedAt: now
            )
            try glossaryTerm.insert(db)
            return glossaryTerm
        }
    }

    func addGlossaryTermReference(
        glossaryTermId: UUID,
        resourceType: CustomerResourceType,
        resourceId: UUID,
        createdAt: Date = .now
    ) throws -> GlossaryTermReferenceRecord {
        try dbQueue.write { db in
            if let existing = try GlossaryTermReferenceRecord
                .filter(
                    Column("glossaryTermId") == glossaryTermId
                        && Column("resourceType") == resourceType
                        && Column("resourceId") == resourceId
                )
                .fetchOne(db) {
                return existing
            }
            let reference = GlossaryTermReferenceRecord(
                glossaryTermId: glossaryTermId,
                resourceType: resourceType,
                resourceId: resourceId,
                createdAt: createdAt
            )
            try reference.insert(db)
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

    private static func validatedJSONObject(_ value: String) throws -> String {
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
