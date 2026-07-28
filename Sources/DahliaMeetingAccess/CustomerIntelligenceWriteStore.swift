import DahliaRuntimeSupport
import Foundation
import GRDB

// swiftlint:disable file_length
enum CustomerIntelligenceWriteLimits {
    static let email = 320
    static let shortText = 256
    static let description = 4000
    static let topicState = 4000
    static let topicNote = 2000
    static let insightContent = 10000
    static let metadataJSON = 65536
}

public extension MeetingAccessStore {
    func createOrganization(
        name: String,
        nodeKind: OrganizationAccessNodeKind,
        parentOrganizationID: UUID?,
        description: String = ""
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard let name = normalizedCustomerText(name),
              let description = normalizedCustomerDescription(description),
              parentOrganizationID != nil || nodeKind == .organization
        else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let id = customerIntelligenceUUIDv7()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO organizations
                    (id, vaultId, parentOrganizationId, nodeKind, name, description, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [
                    id,
                    vaultID,
                    parentOrganizationID,
                    nodeKind.rawValue,
                    name,
                    description,
                    Date.now,
                    Date.now,
                ]
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .organization,
            resourceID: id,
            revision: 1,
            changed: true
        )
    }

    func updateOrganization(
        id: UUID,
        expectedRevision: Int,
        name: String?,
        description: String? = nil,
        parent: OrganizationParentMutation
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let normalizedName = try name.map {
            guard let value = normalizedCustomerText($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        let normalizedDescription = try description.map {
            guard let value = normalizedCustomerDescription($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        guard normalizedName != nil || normalizedDescription != nil || parent != .unchanged else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT name, description, parentOrganizationId, revision
                FROM organizations WHERE id = ? AND vaultId = ?
                """,
                arguments: [id, vaultID]
            ) else {
                throw MeetingAccessError.organizationNotFound
            }
            let revision: Int = row["revision"]
            guard revision == expectedRevision else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            let currentName: String = row["name"]
            let currentDescription: String = row["description"]
            let currentParent: UUID? = row["parentOrganizationId"]
            let nextParent: UUID? = switch parent {
            case .unchanged: currentParent
            case .root: nil
            case let .organization(parentID): parentID
            }
            let nextName = normalizedName ?? currentName
            let nextDescription = normalizedDescription ?? currentDescription
            guard nextName != currentName
                || nextDescription != currentDescription
                || nextParent != currentParent
            else {
                return (revision, false)
            }
            try db.execute(
                sql: """
                UPDATE organizations
                SET name = ?, description = ?, parentOrganizationId = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND revision = ?
                """,
                arguments: [nextName, nextDescription, nextParent, Date.now, id, vaultID, expectedRevision]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            return (revision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .organization,
            resourceID: id,
            revision: result.0,
            changed: result.1
        )
    }

    func createContact(
        email: String?,
        displayName: String?
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let normalizedEmail = normalizedCustomerEmail(email)
        guard displayName?.count ?? 0 <= CustomerIntelligenceWriteLimits.shortText else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let normalizedName = normalizedCustomerText(displayName)
            ?? normalizedEmail.flatMap(customerDisplayNameFromEmail)
        guard email == nil || normalizedEmail != nil, normalizedEmail != nil || normalizedName != nil else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let id = customerIntelligenceUUIDv7()
        try database.write { db in
            if let normalizedEmail {
                try ensureUnusedContactEmail(normalizedEmail, excluding: nil, in: db)
            }
            try db.execute(
                sql: """
                INSERT INTO contacts
                    (id, vaultId, email, displayName, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, normalizedEmail, normalizedName, Date.now, Date.now]
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .contact,
            resourceID: id,
            revision: 1,
            changed: true
        )
    }

    func updateContact(
        id: UUID,
        expectedRevision: Int,
        email: String?,
        displayName: String?
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let normalizedEmail = try email.map {
            guard let value = normalizedCustomerEmail($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        let normalizedName = try displayName.map {
            guard let value = normalizedCustomerText($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        guard normalizedEmail != nil || normalizedName != nil else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT email, displayName, revision FROM contacts WHERE id = ? AND vaultId = ?",
                arguments: [id, vaultID]
            ) else {
                throw MeetingAccessError.contactNotFound
            }
            let revision: Int = row["revision"]
            guard revision == expectedRevision else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            let nextEmail = normalizedEmail ?? (row["email"] as String?)
            let nextName = normalizedName ?? (row["displayName"] as String?)
                ?? nextEmail.flatMap(customerDisplayNameFromEmail)
            if let normalizedEmail {
                try ensureUnusedContactEmail(normalizedEmail, excluding: id, in: db)
            }
            guard nextEmail != (row["email"] as String?) || nextName != (row["displayName"] as String?) else {
                return (revision, false)
            }
            try db.execute(
                sql: """
                UPDATE contacts
                SET email = ?, displayName = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND revision = ?
                """,
                arguments: [nextEmail, nextName, Date.now, id, vaultID, expectedRevision]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            return (revision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .contact,
            resourceID: id,
            revision: result.0,
            changed: result.1
        )
    }

    func resolveContact(
        provisionalContactID: UUID,
        provisionalRevision: Int,
        identifiedContactID: UUID,
        identifiedRevision: Int
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard provisionalContactID != identifiedContactID else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let revision = try database.write { db -> Int in
            guard let source = try Row.fetchOne(
                db,
                sql: "SELECT email, displayName, revision FROM contacts WHERE id = ? AND vaultId = ?",
                arguments: [provisionalContactID, vaultID]
            ), let target = try Row.fetchOne(
                db,
                sql: "SELECT email, displayName, revision FROM contacts WHERE id = ? AND vaultId = ?",
                arguments: [identifiedContactID, vaultID]
            ) else {
                throw MeetingAccessError.contactNotFound
            }
            guard (source["email"] as String?) == nil, (target["email"] as String?) != nil else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            guard (source["revision"] as Int) == provisionalRevision,
                  (target["revision"] as Int) == identifiedRevision
            else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            let targetName: String? = target["displayName"]
            let sourceName: String? = source["displayName"]
            let now = Date.now
            try moveContactReferences(
                from: provisionalContactID,
                to: identifiedContactID,
                now: now,
                in: db
            )
            try db.execute(
                sql: """
                UPDATE contacts
                SET displayName = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [targetName ?? sourceName, now, identifiedContactID, vaultID]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            try db.execute(
                sql: "DELETE FROM contacts WHERE id = ? AND vaultId = ?",
                arguments: [provisionalContactID, vaultID]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT revision FROM contacts WHERE id = ? AND vaultId = ?",
                arguments: [identifiedContactID, vaultID]
            ) ?? identifiedRevision + 1
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .contact,
            resourceID: identifiedContactID,
            revision: revision,
            changed: true
        )
    }

    func createConversationTopic(
        title: String,
        currentState: String
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard let title = normalizedCustomerText(title),
              let currentState = normalizedCustomerText(
                  currentState,
                  maximumLength: CustomerIntelligenceWriteLimits.topicState
              )
        else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let id = customerIntelligenceUUIDv7()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_topics
                    (id, vaultId, title, currentState, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, title, currentState, Date.now, Date.now]
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .conversationTopic,
            resourceID: id,
            revision: 1,
            changed: true
        )
    }

    func updateConversationTopic(
        id: UUID,
        expectedRevision: Int,
        title: String?,
        currentState: String?
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let normalizedTitle = try title.map {
            guard let value = normalizedCustomerText($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        let normalizedState = try currentState.map {
            guard let value = normalizedCustomerText(
                $0,
                maximumLength: CustomerIntelligenceWriteLimits.topicState
            ) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        guard normalizedTitle != nil || normalizedState != nil else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT title, currentState, revision FROM conversation_topics WHERE id = ? AND vaultId = ?",
                arguments: [id, vaultID]
            ) else {
                throw MeetingAccessError.conversationTopicNotFound
            }
            let revision: Int = row["revision"]
            guard revision == expectedRevision else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            let nextTitle = normalizedTitle ?? (row["title"] as String)
            let nextState = normalizedState ?? (row["currentState"] as String)
            guard nextTitle != (row["title"] as String) || nextState != (row["currentState"] as String) else {
                return (revision, false)
            }
            try db.execute(
                sql: """
                UPDATE conversation_topics
                SET title = ?, currentState = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND revision = ?
                """,
                arguments: [nextTitle, nextState, Date.now, id, vaultID, expectedRevision]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            return (revision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .conversationTopic,
            resourceID: id,
            revision: result.0,
            changed: result.1
        )
    }

    func createInsight(
        content: String,
        isAccepted: Bool,
        metadataJSON: String?
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard let content = normalizedCustomerText(
            content,
            maximumLength: CustomerIntelligenceWriteLimits.insightContent
        ),
            let metadataJSON = normalizedCustomerMetadata(metadataJSON)
        else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let id = customerIntelligenceUUIDv7()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO insights
                    (id, vaultId, content, isAccepted, metadataJSON, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, content, isAccepted, metadataJSON, Date.now, Date.now]
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .insight,
            resourceID: id,
            revision: 1,
            changed: true
        )
    }

    func updateInsight(
        id: UUID,
        expectedRevision: Int,
        content: String?,
        isAccepted: Bool?,
        metadataJSON: String?
    ) throws -> CustomerIntelligenceRecordMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let normalizedContent = try content.map {
            guard let value = normalizedCustomerText(
                $0,
                maximumLength: CustomerIntelligenceWriteLimits.insightContent
            ) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        let normalizedMetadata = try metadataJSON.map {
            guard let value = normalizedCustomerMetadata($0) else {
                throw MeetingAccessError.invalidCustomerIntelligenceMutation
            }
            return value
        }
        guard normalizedContent != nil || isAccepted != nil || normalizedMetadata != nil else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT content, isAccepted, metadataJSON, revision
                FROM insights WHERE id = ? AND vaultId = ?
                """,
                arguments: [id, vaultID]
            ) else {
                throw MeetingAccessError.insightNotFound
            }
            let revision: Int = row["revision"]
            guard revision == expectedRevision else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            let nextContent = normalizedContent ?? (row["content"] as String)
            let nextAccepted = isAccepted ?? (row["isAccepted"] as Bool)
            let nextMetadata = normalizedMetadata ?? (row["metadataJSON"] as String)
            guard nextContent != (row["content"] as String)
                || nextAccepted != (row["isAccepted"] as Bool)
                || nextMetadata != (row["metadataJSON"] as String)
            else {
                return (revision, false)
            }
            try db.execute(
                sql: """
                UPDATE insights
                SET content = ?, isAccepted = ?, metadataJSON = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND revision = ?
                """,
                arguments: [
                    nextContent, nextAccepted, nextMetadata, Date.now, id, vaultID, expectedRevision,
                ]
            )
            guard db.changesCount == 1 else {
                throw MeetingAccessError.customerIntelligenceRevisionConflict
            }
            return (revision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRecordMutationResult(
            vault: vault,
            resourceType: .insight,
            resourceID: id,
            revision: result.0,
            changed: result.1
        )
    }

    func deleteOrganization(
        id: UUID,
        expectedRevision: Int
    ) throws -> CustomerIntelligenceRecordDeletionResult {
        try requireCustomerIntelligenceWriteAccess()
        let vault = try scopedVault()
        try database.write { db in
            _ = try requiredRevision(
                table: "organizations",
                id: id,
                expected: expectedRevision,
                notFound: .organizationNotFound,
                in: db
            )
            let childCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM organizations WHERE parentOrganizationId = ? AND vaultId = ?",
                arguments: [id, vaultID]
            ) ?? 0
            let memberCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM organization_memberships WHERE organizationId = ?",
                arguments: [id]
            ) ?? 0
            let blockers = [
                ("child_organizations", childCount),
                ("contact_memberships", memberCount),
            ]
            try ensureNoDeletionBlockers(resource: "Organization", blockers: blockers)
            try incrementReferenceOwners(resourceType: .organization, resourceID: id, in: db)
            try deleteRecord(
                table: "organizations",
                id: id,
                expectedRevision: expectedRevision,
                in: db
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordDeletionResult(
            vault: vault,
            resourceType: .organization,
            resourceID: id,
            changed: true
        )
    }

    func deleteContact(
        id: UUID,
        expectedRevision: Int
    ) throws -> CustomerIntelligenceRecordDeletionResult {
        try requireCustomerIntelligenceWriteAccess()
        let vault = try scopedVault()
        try database.write { db in
            _ = try requiredRevision(
                table: "contacts",
                id: id,
                expected: expectedRevision,
                notFound: .contactNotFound,
                in: db
            )
            let blockers = try [
                ("organization_memberships", countRows(
                    "SELECT COUNT(*) FROM organization_memberships WHERE contactId = ?",
                    arguments: [id],
                    in: db
                )),
                ("meeting_participants", countRows(
                    "SELECT COUNT(*) FROM meeting_participants WHERE contactId = ?",
                    arguments: [id],
                    in: db
                )),
                ("project_references", countRows(
                    """
                    SELECT COUNT(*) FROM project_resource_references
                    WHERE resourceType = 'contact' AND resourceId = ?
                    """,
                    arguments: [id],
                    in: db
                )),
                ("topic_references", countRows(
                    """
                    SELECT COUNT(*) FROM conversation_topic_references
                    WHERE resourceType = 'contact' AND resourceId = ?
                    """,
                    arguments: [id],
                    in: db
                )),
                ("insight_references", countRows(
                    """
                    SELECT COUNT(*) FROM insight_references
                    WHERE resourceType = 'contact' AND resourceId = ?
                    """,
                    arguments: [id],
                    in: db
                )),
            ]
            try ensureNoDeletionBlockers(resource: "Contact", blockers: blockers)
            try deleteRecord(
                table: "contacts",
                id: id,
                expectedRevision: expectedRevision,
                in: db
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordDeletionResult(
            vault: vault,
            resourceType: .contact,
            resourceID: id,
            changed: true
        )
    }

    func deleteConversationTopic(
        id: UUID,
        expectedRevision: Int
    ) throws -> CustomerIntelligenceRecordDeletionResult {
        try deleteCustomerIntelligenceRecord(
            table: "conversation_topics",
            id: id,
            expectedRevision: expectedRevision,
            notFound: .conversationTopicNotFound,
            resourceType: .conversationTopic
        )
    }

    func deleteInsight(
        id: UUID,
        expectedRevision: Int
    ) throws -> CustomerIntelligenceRecordDeletionResult {
        try deleteCustomerIntelligenceRecord(
            table: "insights",
            id: id,
            expectedRevision: expectedRevision,
            notFound: .insightNotFound,
            resourceType: .insight
        )
    }

    func setContactOrganizationMembership(
        contactID: UUID,
        organizationID: UUID,
        expectedOrganizationRevision: Int,
        roleLabel: String?
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeContactOrganizationMembership(
            contactID: contactID,
            organizationID: organizationID,
            expectedOrganizationRevision: expectedOrganizationRevision,
            roleLabel: roleLabel,
            removes: false
        )
    }

    func removeContactOrganizationMembership(
        contactID: UUID,
        organizationID: UUID,
        expectedOrganizationRevision: Int
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeContactOrganizationMembership(
            contactID: contactID,
            organizationID: organizationID,
            expectedOrganizationRevision: expectedOrganizationRevision,
            roleLabel: nil,
            removes: true
        )
    }

    func setProjectResourceReference(
        projectID: UUID,
        expectedProjectRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        relationLabel: String?
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeProjectResourceReference(
            projectID: projectID,
            expectedProjectRevision: expectedProjectRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            relationLabel: relationLabel,
            removes: false
        )
    }

    func removeProjectResourceReference(
        projectID: UUID,
        expectedProjectRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeProjectResourceReference(
            projectID: projectID,
            expectedProjectRevision: expectedProjectRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            relationLabel: nil,
            removes: true
        )
    }

    func setConversationTopicResourceReference(
        topicID: UUID,
        expectedTopicRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        note: String?
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeConversationTopicResourceReference(
            topicID: topicID,
            expectedTopicRevision: expectedTopicRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            note: note,
            removes: false
        )
    }

    func removeConversationTopicResourceReference(
        topicID: UUID,
        expectedTopicRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeConversationTopicResourceReference(
            topicID: topicID,
            expectedTopicRevision: expectedTopicRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            note: nil,
            removes: true
        )
    }

    func setInsightResourceReference(
        insightID: UUID,
        expectedInsightRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        referenceRole: InsightAccessReferenceRole
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeInsightResourceReference(
            insightID: insightID,
            expectedInsightRevision: expectedInsightRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            referenceRole: referenceRole,
            removes: false
        )
    }

    func removeInsightResourceReference(
        insightID: UUID,
        expectedInsightRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeInsightResourceReference(
            insightID: insightID,
            expectedInsightRevision: expectedInsightRevision,
            resourceType: resourceType,
            resourceID: resourceID,
            referenceRole: nil,
            removes: true
        )
    }

    func setMeetingProjectAssignment(
        meetingID: UUID,
        expectedProjectID: UUID?,
        projectID: UUID
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeMeetingProjectAssignment(
            meetingID: meetingID,
            expectedProjectID: expectedProjectID,
            projectID: projectID
        )
    }

    func removeMeetingProjectAssignment(
        meetingID: UUID,
        expectedProjectID: UUID?
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try changeMeetingProjectAssignment(
            meetingID: meetingID,
            expectedProjectID: expectedProjectID,
            projectID: nil
        )
    }
}

private extension MeetingAccessStore {
    func deleteCustomerIntelligenceRecord(
        table: String,
        id: UUID,
        expectedRevision: Int,
        notFound: MeetingAccessError,
        resourceType: CustomerIntelligenceDeletionResourceKind
    ) throws -> CustomerIntelligenceRecordDeletionResult {
        try requireCustomerIntelligenceWriteAccess()
        let vault = try scopedVault()
        try database.write { db in
            _ = try requiredRevision(
                table: table,
                id: id,
                expected: expectedRevision,
                notFound: notFound,
                in: db
            )
            try deleteRecord(
                table: table,
                id: id,
                expectedRevision: expectedRevision,
                in: db
            )
        }
        postCustomerIntelligenceChange()
        return CustomerIntelligenceRecordDeletionResult(
            vault: vault,
            resourceType: resourceType,
            resourceID: id,
            changed: true
        )
    }

    func deleteRecord(
        table: String,
        id: UUID,
        expectedRevision: Int,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(table) WHERE id = ? AND vaultId = ? AND revision = ?",
            arguments: [id, vaultID, expectedRevision]
        )
        guard db.changesCount == 1 else {
            throw MeetingAccessError.customerIntelligenceRevisionConflict
        }
    }

    func ensureNoDeletionBlockers(resource: String, blockers: [(String, Int)]) throws {
        let active = blockers.filter { $0.1 > 0 }
        guard active.isEmpty else {
            let details = active.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            throw MeetingAccessError.customerIntelligenceResourceInUse(
                "\(resource) cannot be deleted while it is in use: \(details)."
            )
        }
    }

    func countRows(
        _ sql: String,
        arguments: StatementArguments,
        in db: Database
    ) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    func incrementReferenceOwners(
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        in db: Database
    ) throws {
        let projectIDs = try UUID.fetchAll(
            db,
            sql: """
            SELECT DISTINCT projectId FROM project_resource_references
            WHERE resourceType = ? AND resourceId = ?
            """,
            arguments: [resourceType.rawValue, resourceID]
        )
        let insightIDs = try UUID.fetchAll(
            db,
            sql: """
            SELECT DISTINCT insightId FROM insight_references
            WHERE resourceType = ? AND resourceId = ?
            """,
            arguments: [resourceType.rawValue, resourceID]
        )
        for projectID in projectIDs {
            try incrementRevision(table: "projects", id: projectID, in: db)
        }
        for insightID in insightIDs {
            try incrementRevision(table: "insights", id: insightID, in: db)
        }
    }

    func changeContactOrganizationMembership(
        contactID: UUID,
        organizationID: UUID,
        expectedOrganizationRevision: Int,
        roleLabel: String?,
        removes: Bool
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard roleLabel?.count ?? 0 <= CustomerIntelligenceWriteLimits.shortText else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let normalizedRole = normalizedCustomerText(roleLabel)
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            guard try resourceExists(.contact, id: contactID, in: db) else {
                throw MeetingAccessError.contactNotFound
            }
            let revision = try requiredRevision(
                table: "organizations",
                id: organizationID,
                expected: expectedOrganizationRevision,
                notFound: .organizationNotFound,
                in: db
            )
            let current = try String.fetchOne(
                db,
                sql: """
                SELECT roleLabel FROM organization_memberships
                WHERE organizationId = ? AND contactId = ?
                """,
                arguments: [organizationID, contactID]
            )
            let exists = try Int.fetchOne(
                db,
                sql: """
                SELECT 1 FROM organization_memberships
                WHERE organizationId = ? AND contactId = ?
                """,
                arguments: [organizationID, contactID]
            ) != nil
            if removes {
                guard exists else { return (revision, false) }
                try db.execute(
                    sql: "DELETE FROM organization_memberships WHERE organizationId = ? AND contactId = ?",
                    arguments: [organizationID, contactID]
                )
            } else {
                guard !exists || current != normalizedRole else { return (revision, false) }
                try db.execute(
                    sql: """
                    INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (organizationId, contactId) DO UPDATE SET roleLabel = excluded.roleLabel
                    """,
                    arguments: [organizationID, contactID, normalizedRole, Date.now]
                )
            }
            return try (currentRevision(table: "organizations", id: organizationID, in: db), true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRelationshipMutationResult(
            vault: vault,
            relationship: .contactOrganizationMembership,
            sourceID: contactID,
            targetID: organizationID,
            revision: result.0,
            changed: result.1
        )
    }

    func changeProjectResourceReference(
        projectID: UUID,
        expectedProjectRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        relationLabel: String?,
        removes: Bool
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard resourceType == .organization || resourceType == .contact else {
            throw MeetingAccessError.invalidCustomerIntelligenceReference
        }
        guard relationLabel?.count ?? 0 <= CustomerIntelligenceWriteLimits.shortText else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let label = normalizedCustomerText(relationLabel) ?? ""
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            _ = try requiredRevision(
                table: "projects",
                id: projectID,
                expected: expectedProjectRevision,
                notFound: .projectNotFound,
                in: db
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, relationLabel FROM project_resource_references
                WHERE projectId = ? AND resourceType = ? AND resourceId = ?
                ORDER BY createdAt, id
                """,
                arguments: [projectID, resourceType.rawValue, resourceID]
            )
            if removes {
                guard !rows.isEmpty else { return (expectedProjectRevision, false) }
                try db.execute(
                    sql: """
                    DELETE FROM project_resource_references
                    WHERE projectId = ? AND resourceType = ? AND resourceId = ?
                    """,
                    arguments: [projectID, resourceType.rawValue, resourceID]
                )
            } else {
                guard try resourceExists(resourceType, id: resourceID, in: db) else {
                    throw MeetingAccessError.invalidCustomerIntelligenceReference
                }
                if let first = rows.first {
                    let existing: String = first["relationLabel"]
                    guard rows.count > 1 || existing != label else {
                        return (expectedProjectRevision, false)
                    }
                    let firstID: UUID = first["id"]
                    try db.execute(
                        sql: """
                        DELETE FROM project_resource_references
                        WHERE projectId = ? AND resourceType = ? AND resourceId = ? AND id <> ?
                        """,
                        arguments: [projectID, resourceType.rawValue, resourceID, firstID]
                    )
                    try db.execute(
                        sql: """
                        UPDATE project_resource_references SET relationLabel = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [label, Date.now, firstID]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO project_resource_references
                            (id, projectId, resourceType, resourceId, relationLabel, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            customerIntelligenceUUIDv7(), projectID, resourceType.rawValue, resourceID,
                            label, Date.now, Date.now,
                        ]
                    )
                }
            }
            try incrementRevision(table: "projects", id: projectID, in: db)
            return (expectedProjectRevision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRelationshipMutationResult(
            vault: vault,
            relationship: .projectResourceReference,
            sourceID: projectID,
            targetID: resourceID,
            revision: result.0,
            changed: result.1
        )
    }

    func changeConversationTopicResourceReference(
        topicID: UUID,
        expectedTopicRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        note: String?,
        removes: Bool
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard note?.count ?? 0 <= CustomerIntelligenceWriteLimits.topicNote else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        let normalizedNote = normalizedCustomerText(
            note,
            maximumLength: CustomerIntelligenceWriteLimits.topicNote
        )
        guard resourceType != .meeting || removes || normalizedNote != nil else {
            throw MeetingAccessError.invalidCustomerIntelligenceReference
        }
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            _ = try requiredRevision(
                table: "conversation_topics",
                id: topicID,
                expected: expectedTopicRevision,
                notFound: .conversationTopicNotFound,
                in: db
            )
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT note FROM conversation_topic_references
                WHERE topicId = ? AND resourceType = ? AND resourceId = ?
                """,
                arguments: [topicID, resourceType.rawValue, resourceID]
            )
            if removes {
                guard row != nil else { return (expectedTopicRevision, false) }
                try db.execute(
                    sql: """
                    DELETE FROM conversation_topic_references
                    WHERE topicId = ? AND resourceType = ? AND resourceId = ?
                    """,
                    arguments: [topicID, resourceType.rawValue, resourceID]
                )
            } else {
                guard try resourceExists(resourceType, id: resourceID, in: db) else {
                    throw MeetingAccessError.invalidCustomerIntelligenceReference
                }
                let storedNote = resourceType == .meeting ? normalizedNote : nil
                if let row, (row["note"] as String?) == storedNote {
                    return (expectedTopicRevision, false)
                }
                try db.execute(
                    sql: """
                    INSERT INTO conversation_topic_references
                        (topicId, resourceType, resourceId, note, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (topicId, resourceType, resourceId)
                    DO UPDATE SET note = excluded.note, updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        topicID, resourceType.rawValue, resourceID, storedNote, Date.now, Date.now,
                    ]
                )
            }
            return try (currentRevision(table: "conversation_topics", id: topicID, in: db), true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRelationshipMutationResult(
            vault: vault,
            relationship: .conversationTopicResourceReference,
            sourceID: topicID,
            targetID: resourceID,
            revision: result.0,
            changed: result.1
        )
    }

    func changeInsightResourceReference(
        insightID: UUID,
        expectedInsightRevision: Int,
        resourceType: CustomerResourceAccessType,
        resourceID: UUID,
        referenceRole: InsightAccessReferenceRole?,
        removes: Bool
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        let vault = try scopedVault()
        let result = try database.write { db -> (Int, Bool) in
            _ = try requiredRevision(
                table: "insights",
                id: insightID,
                expected: expectedInsightRevision,
                notFound: .insightNotFound,
                in: db
            )
            let roles = try String.fetchAll(
                db,
                sql: """
                SELECT referenceRole FROM insight_references
                WHERE insightId = ? AND resourceType = ? AND resourceId = ?
                """,
                arguments: [insightID, resourceType.rawValue, resourceID]
            )
            if removes {
                guard !roles.isEmpty else { return (expectedInsightRevision, false) }
                try db.execute(
                    sql: """
                    DELETE FROM insight_references
                    WHERE insightId = ? AND resourceType = ? AND resourceId = ?
                    """,
                    arguments: [insightID, resourceType.rawValue, resourceID]
                )
            } else {
                guard try resourceExists(resourceType, id: resourceID, in: db) else {
                    throw MeetingAccessError.invalidCustomerIntelligenceReference
                }
                guard let referenceRole else {
                    throw MeetingAccessError.invalidCustomerIntelligenceReference
                }
                guard roles.count != 1 || roles.first != referenceRole.rawValue else {
                    return (expectedInsightRevision, false)
                }
                try db.execute(
                    sql: """
                    DELETE FROM insight_references
                    WHERE insightId = ? AND resourceType = ? AND resourceId = ?
                    """,
                    arguments: [insightID, resourceType.rawValue, resourceID]
                )
                try db.execute(
                    sql: """
                    INSERT INTO insight_references
                        (insightId, resourceType, resourceId, referenceRole, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        insightID, resourceType.rawValue, resourceID, referenceRole.rawValue, Date.now,
                    ]
                )
            }
            try incrementRevision(table: "insights", id: insightID, in: db)
            return (expectedInsightRevision + 1, true)
        }
        if result.1 { postCustomerIntelligenceChange() }
        return CustomerIntelligenceRelationshipMutationResult(
            vault: vault,
            relationship: .insightResourceReference,
            sourceID: insightID,
            targetID: resourceID,
            revision: result.0,
            changed: result.1
        )
    }

    func changeMeetingProjectAssignment(
        meetingID: UUID,
        expectedProjectID: UUID?,
        projectID: UUID?
    ) throws -> CustomerIntelligenceRelationshipMutationResult {
        let result = try setMeetingProjectMemberships(
            [MeetingProjectMembershipExpectation(meetingID: meetingID, expectedProjectID: expectedProjectID)],
            projectID: projectID
        )
        return try CustomerIntelligenceRelationshipMutationResult(
            vault: scopedVault(),
            relationship: .meetingProjectAssignment,
            sourceID: meetingID,
            targetID: projectID,
            revision: nil,
            changed: result.changed
        )
    }

    func requireCustomerIntelligenceWriteAccess() throws {
        guard allowsWrites else { throw MeetingAccessError.writeAccessRequired }
    }

    func ensureUnusedContactEmail(_ email: String, excluding id: UUID?, in db: Database) throws {
        let existing = try UUID.fetchOne(
            db,
            sql: "SELECT id FROM contacts WHERE vaultId = ? AND email = ?",
            arguments: [vaultID, email]
        )
        guard existing == nil || existing == id else {
            throw MeetingAccessError.duplicateContactEmail
        }
    }

    func requiredRevision(
        table: String,
        id: UUID,
        expected: Int,
        notFound: MeetingAccessError,
        in db: Database
    ) throws -> Int {
        guard let revision = try Int.fetchOne(
            db,
            sql: "SELECT revision FROM \(table) WHERE id = ? AND vaultId = ?",
            arguments: [id, vaultID]
        ) else {
            throw notFound
        }
        guard revision == expected else {
            throw MeetingAccessError.customerIntelligenceRevisionConflict
        }
        return revision
    }

    func currentRevision(table: String, id: UUID, in db: Database) throws -> Int {
        guard let revision = try Int.fetchOne(
            db,
            sql: "SELECT revision FROM \(table) WHERE id = ? AND vaultId = ?",
            arguments: [id, vaultID]
        ) else {
            throw MeetingAccessError.invalidCustomerIntelligenceMutation
        }
        return revision
    }

    func incrementRevision(table: String, id: UUID, in db: Database) throws {
        if table == "projects" {
            try db.execute(
                sql: "UPDATE projects SET revision = revision + 1 WHERE id = ? AND vaultId = ?",
                arguments: [id, vaultID]
            )
        } else {
            try db.execute(
                sql: "UPDATE \(table) SET revision = revision + 1, updatedAt = ? WHERE id = ? AND vaultId = ?",
                arguments: [Date.now, id, vaultID]
            )
        }
        guard db.changesCount == 1 else {
            throw MeetingAccessError.customerIntelligenceRevisionConflict
        }
    }

    func resourceExists(
        _ type: CustomerResourceAccessType,
        id: UUID,
        in db: Database
    ) throws -> Bool {
        let table = switch type {
        case .organization: "organizations"
        case .contact: "contacts"
        case .project: "projects"
        case .meeting: "meetings"
        }
        return try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM \(table) WHERE id = ? AND vaultId = ?",
            arguments: [id, vaultID]
        ) != nil
    }

    func moveContactReferences(from source: UUID, to target: UUID, now: Date, in db: Database) throws {
        let projectIDs = try UUID.fetchAll(
            db,
            sql: """
            SELECT DISTINCT projectId FROM project_resource_references
            WHERE resourceType = 'contact' AND resourceId = ?
            """,
            arguments: [source]
        )
        let insightIDs = try UUID.fetchAll(
            db,
            sql: """
            SELECT DISTINCT insightId FROM insight_references
            WHERE resourceType = 'contact' AND resourceId = ?
            """,
            arguments: [source]
        )
        try db.execute(
            sql: CustomerIntelligenceContactReferenceMerge.sql,
            arguments: ["targetID": target, "sourceID": source, "now": now]
        )
        for projectID in projectIDs {
            try incrementRevision(table: "projects", id: projectID, in: db)
        }
        for insightID in insightIDs {
            try incrementRevision(table: "insights", id: insightID, in: db)
        }
    }

    func normalizedCustomerText(
        _ value: String?,
        maximumLength: Int = CustomerIntelligenceWriteLimits.shortText
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maximumLength ? nil : trimmed
    }

    func normalizedCustomerDescription(_ value: String) -> String? {
        guard value.count <= CustomerIntelligenceWriteLimits.description else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedCustomerMetadata(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let metadata = trimmed.isEmpty ? "{}" : trimmed
        guard metadata.count <= CustomerIntelligenceWriteLimits.metadataJSON,
              let data = metadata.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else {
            return nil
        }
        return metadata
    }

    func normalizedCustomerEmail(_ value: String?) -> String? {
        guard let value, value.count <= CustomerIntelligenceWriteLimits.email else { return nil }
        return CustomerIdentityNormalizer.email(value)
    }

    func customerDisplayNameFromEmail(_ email: String) -> String? {
        email.split(separator: "@", maxSplits: 1).first
            .map(String.init)
            .flatMap { normalizedCustomerText($0) }
    }

    func postCustomerIntelligenceChange() {
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
    }

    func customerIntelligenceUUIDv7() -> UUID {
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (
            UInt8(truncatingIfNeeded: milliseconds >> 40),
            UInt8(truncatingIfNeeded: milliseconds >> 32),
            UInt8(truncatingIfNeeded: milliseconds >> 24),
            UInt8(truncatingIfNeeded: milliseconds >> 16),
            UInt8(truncatingIfNeeded: milliseconds >> 8),
            UInt8(truncatingIfNeeded: milliseconds),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for index in 6 ..< 16 {
                buffer[index] = UInt8.random(in: 0 ... 255)
            }
        }
        bytes.6 = (bytes.6 & 0x0F) | 0x70
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }
}
