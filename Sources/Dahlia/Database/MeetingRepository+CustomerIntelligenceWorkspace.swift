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

    nonisolated func fetchUnassignedContacts(vaultId: UUID) throws -> [ContactRecord] {
        try dbQueue.read { db in
            try ContactRecord
                .filter(Column("vaultId") == vaultId)
                .filter(sql: """
                NOT EXISTS (
                    SELECT 1 FROM organization_memberships
                    WHERE organization_memberships.contactId = contacts.id
                )
                """)
                .order(Column("displayName").asc, Column("email").asc, Column("id").asc)
                .limit(500)
                .fetchAll(db)
        }
    }

    nonisolated func searchOrganizationWorkspaceNodes(
        vaultId: UUID,
        query: String,
        limit: Int = 50
    ) throws -> [OrganizationRecord] {
        try dbQueue.read { db in
            try OrganizationRecord
                .filter(Column("vaultId") == vaultId)
                .filter(Column("name").like("%\(query)%"))
                .order(Column("name").asc, Column("id").asc)
                .limit(min(max(limit, 1), 100))
                .fetchAll(db)
        }
    }

    nonisolated func fetchOrganizationWorkspaceDetail(
        organizationId: UUID,
        vaultId: UUID
    ) throws -> OrganizationWorkspaceDetail {
        try dbQueue.read { db in
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

    nonisolated func fetchConversationTopicRelatedOrganizationIDs(
        id: UUID,
        vaultId: UUID
    ) throws -> [UUID] {
        try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: """
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
                ORDER BY 1
                """,
                arguments: [id, vaultId, id, vaultId, vaultId]
            )
        }
    }

    func createConversationTopic(
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
                throw CustomerIntelligenceError.proposalConflict
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
                throw CustomerIntelligenceError.proposalConflict
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
        now: Date = .now
    ) throws {
        try dbQueue.write { db in
            guard let topic = try ConversationTopicRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db)
            else {
                throw CustomerIntelligenceError.topicNotFound
            }
            guard expectedRevision.map({ $0 == topic.revision }) ?? true else {
                throw CustomerIntelligenceError.proposalConflict
            }
            if let expectedImpact,
               try Self.topicDeletionImpact(id: id, vaultId: vaultId, in: db) != expectedImpact {
                throw CustomerIntelligenceError.proposalConflict
            }
            try Self.markProposalsStale(
                vaultId: vaultId,
                referencing: [id],
                reason: "topicDeleted",
                now: now,
                in: db
            )
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
                    throw CustomerIntelligenceError.proposalConflict
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
                throw CustomerIntelligenceError.proposalConflict
            }
            guard impact.meetingParticipants == 0 else {
                throw CustomerIntelligenceError.provisionalContactHasParticipant
            }
            try Self.markProposalsStale(
                vaultId: vaultId,
                referencing: [id],
                reason: "contactDeleted",
                now: now,
                in: db
            )
            _ = try ContactRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Proposals

    nonisolated func fetchCustomerIntelligenceProposals(
        vaultId: UUID,
        status: CustomerIntelligenceProposalStatus? = nil
    ) throws -> [CustomerIntelligenceProposalOverview] {
        try dbQueue.read { db in
            var request = CustomerIntelligenceProposalRecord.filter(Column("vaultId") == vaultId)
            if let status {
                request = request.filter(Column("status") == status)
            }
            let proposals = try request
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(500)
                .fetchAll(db)
            guard !proposals.isEmpty else { return [] }
            let proposalIDs = Set(proposals.map(\.id))
            let evidenceByProposal = try Dictionary(
                grouping: CustomerIntelligenceProposalEvidenceRecord
                    .filter(proposalIDs.contains(Column("proposalId")))
                    .order(Column("createdAt").asc)
                    .fetchAll(db),
                by: \.proposalId
            )
            let dependenciesByProposal = try Dictionary(
                grouping: CustomerIntelligenceProposalDependencyRecord
                    .filter(proposalIDs.contains(Column("proposalId")))
                    .order(Column("createdAt").asc, Column("requiredProposalId").asc)
                    .fetchAll(db),
                by: \.proposalId
            )
            return proposals.map { proposal in
                CustomerIntelligenceProposalOverview(
                    proposal: proposal,
                    evidence: evidenceByProposal[proposal.id, default: []],
                    dependencies: dependenciesByProposal[proposal.id, default: []].map(\.requiredProposalId)
                )
            }
        }
    }

    @discardableResult
    func proposeCustomerIntelligenceChanges(
        vaultId: UUID,
        inputs: [CustomerIntelligenceProposalInput],
        now: Date = .now
    ) throws -> [String: UUID] {
        let prepared = try Self.prepareProposalBatch(inputs)
        return try dbQueue.write { db in
            guard try VaultRecord.fetchOne(db, key: vaultId) != nil else {
                throw CustomerIntelligenceError.vaultNotFound
            }
            var proposalIDs: [String: UUID] = [:]
            var entityIDs: [String: UUID] = [:]
            for input in prepared {
                proposalIDs[input.localKey] = .v7()
                if Self.createsEntity(input.operationType) {
                    entityIDs[input.localKey] = .v7()
                }
            }
            let newEntityKinds: [UUID: CustomerIntelligenceResourceKind] = Dictionary(
                uniqueKeysWithValues: prepared.compactMap { input -> (UUID, CustomerIntelligenceResourceKind)? in
                    guard let id = entityIDs[input.localKey],
                          let kind = Self.createdResourceKind(input.operationType) else { return nil }
                    return (id, kind)
                }
            )
            for input in prepared {
                guard let proposalID = proposalIDs[input.localKey] else {
                    throw CustomerIntelligenceError.invalidProposal
                }
                var payload = input.payload
                if let entityID = entityIDs[input.localKey] {
                    payload.targetID = entityID
                }
                try Self.resolveLocalReferences(in: &payload, entityIDs: entityIDs)
                guard payload.references.map(CustomerIntelligenceProposalLimits.containsTopicReferences) ?? true
                else {
                    throw CustomerIntelligenceError.invalidProposal
                }
                try Self.validateProposalResources(
                    operation: input.operationType,
                    payload: payload,
                    vaultId: vaultId,
                    newEntityKinds: newEntityKinds,
                    in: db
                )
                for evidence in input.evidence {
                    guard try Self.resource(
                        evidence.resourceType,
                        id: evidence.resourceID,
                        existsIn: vaultId,
                        in: db
                    ) else {
                        throw CustomerIntelligenceError.invalidProposal
                    }
                }
                let payloadJSON = try Self.encodePayload(payload)
                try CustomerIntelligenceProposalRecord(
                    id: proposalID,
                    vaultId: vaultId,
                    operationType: input.operationType.rawValue,
                    payloadJSON: payloadJSON,
                    status: .proposed,
                    staleReason: nil,
                    revision: 1,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                for evidence in input.evidence {
                    try CustomerIntelligenceProposalEvidenceRecord(
                        proposalId: proposalID,
                        resourceType: evidence.resourceType.rawValue,
                        resourceId: evidence.resourceID,
                        note: Self.normalizedText(evidence.note),
                        createdAt: now
                    ).insert(db)
                }
                for dependencyKey in input.dependsOn {
                    guard let requiredID = proposalIDs[dependencyKey] else {
                        throw CustomerIntelligenceError.proposalDependency
                    }
                    try CustomerIntelligenceProposalDependencyRecord(
                        proposalId: proposalID,
                        requiredProposalId: requiredID,
                        createdAt: now
                    ).insert(db)
                }
            }
            return proposalIDs
        }
    }

    nonisolated func applyCustomerIntelligenceProposals(
        vaultId: UUID,
        revisions: [UUID: Int],
        now: Date = .now
    ) throws {
        guard (1 ... 100).contains(revisions.count) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        let proposalIDs = Set(revisions.keys)
        let prepared = try dbQueue.read { db in
            try Dictionary(
                uniqueKeysWithValues: proposalIDs.map { id in
                    guard let proposal = try CustomerIntelligenceProposalRecord
                        .filter(Column("id") == id && Column("vaultId") == vaultId)
                        .fetchOne(db),
                        let operation = CustomerIntelligenceProposalOperationType(
                            rawValue: proposal.operationType
                        )
                    else {
                        throw CustomerIntelligenceError.proposalNotFound
                    }
                    let payload = try Self.decodePayload(proposal.payloadJSON)
                    try Self.validatePayload(payload, for: operation)
                    return (
                        id,
                        (
                            operationType: proposal.operationType,
                            payloadJSON: proposal.payloadJSON,
                            payload: payload
                        )
                    )
                }
            )
        }
        try dbQueue.write { db in
            let proposals = try proposalIDs.map { id -> CustomerIntelligenceProposalRecord in
                guard let proposal = try CustomerIntelligenceProposalRecord
                    .filter(Column("id") == id && Column("vaultId") == vaultId)
                    .fetchOne(db),
                    let decoded = prepared[id],
                    proposal.operationType == decoded.operationType,
                    proposal.payloadJSON == decoded.payloadJSON
                else {
                    throw CustomerIntelligenceError.proposalConflict
                }
                guard proposal.status == .proposed, proposal.revision == revisions[id] else {
                    throw CustomerIntelligenceError.proposalConflict
                }
                return proposal
            }
            let order = try Self.proposalApplyOrder(proposals: proposals, selected: proposalIDs, in: db)
            try Self.rejectContactResolutionCollisions(order, payloads: prepared)
            for proposal in order {
                guard let payload = prepared[proposal.id]?.payload else {
                    throw CustomerIntelligenceError.proposalConflict
                }
                try Self.validateExpectations(
                    operationType: proposal.operationType,
                    payload: payload,
                    vaultId: vaultId,
                    in: db
                )
                try Self.apply(
                    proposalID: proposal.id,
                    operationType: proposal.operationType,
                    payload: payload,
                    vaultId: vaultId,
                    now: now,
                    in: db
                )
                var applied = proposal
                applied.status = .applied
                applied.revision += 1
                applied.updatedAt = now
                try applied.update(db)
            }
        }
    }

    nonisolated func rejectCustomerIntelligenceProposals(
        vaultId: UUID,
        revisions: [UUID: Int],
        now: Date = .now
    ) throws {
        guard (1 ... 100).contains(revisions.count) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        try dbQueue.write { db in
            for (id, revision) in revisions {
                guard var proposal = try CustomerIntelligenceProposalRecord
                    .filter(Column("id") == id && Column("vaultId") == vaultId)
                    .fetchOne(db)
                else {
                    throw CustomerIntelligenceError.proposalNotFound
                }
                guard proposal.status == .proposed || proposal.status == .stale,
                      proposal.revision == revision else {
                    throw CustomerIntelligenceError.proposalConflict
                }
                proposal.status = .rejected
                proposal.staleReason = nil
                proposal.revision += 1
                proposal.updatedAt = now
                try proposal.update(db)
            }
        }
    }

    // MARK: - Proposal validation and application

    private nonisolated static func prepareProposalBatch(
        _ inputs: [CustomerIntelligenceProposalInput]
    ) throws -> [CustomerIntelligenceProposalInput] {
        guard CustomerIntelligenceProposalLimits.containsBatch(inputs) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        let keys = inputs.map(\.localKey)
        let allKeys = Set(keys)
        guard allKeys.count == keys.count,
              keys.allSatisfy({ normalizedText($0) != nil }),
              inputs.allSatisfy({
                  let dependencies = Set($0.dependsOn)
                  return dependencies.isSubset(of: allKeys)
                      && $0.payload.referencedLocalKeys.isSubset(of: dependencies)
              })
        else {
            throw CustomerIntelligenceError.invalidProposal
        }
        let inputsByKey = Dictionary(uniqueKeysWithValues: inputs.map { ($0.localKey, $0) })
        var remaining = Dictionary(uniqueKeysWithValues: inputs.map { ($0.localKey, Set($0.dependsOn)) })
        var ordered: [CustomerIntelligenceProposalInput] = []
        while !remaining.isEmpty {
            let ready = remaining.filter(\.value.isEmpty).map(\.key).sorted()
            guard !ready.isEmpty else { throw CustomerIntelligenceError.proposalCycle }
            for key in ready {
                guard let input = inputsByKey[key] else {
                    throw CustomerIntelligenceError.invalidProposal
                }
                ordered.append(input)
                remaining.removeValue(forKey: key)
                for dependencyKey in remaining.keys {
                    remaining[dependencyKey]?.remove(key)
                }
            }
        }
        for input in ordered {
            try validatePayload(input.payload, for: input.operationType)
        }
        return ordered
    }

    private nonisolated static func validatePayload(
        _ payload: CustomerIntelligenceProposalPayload,
        for operation: CustomerIntelligenceProposalOperationType
    ) throws {
        guard CustomerIntelligenceProposalLimits.contains(CustomerIntelligenceProposalInput(
            localKey: "stored",
            operationType: operation,
            payload: payload
        )) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        let expectationFields = payload.expectations.map(\.field)
        let expectationFieldSet = Set(expectationFields)
        guard expectationFieldSet.count == expectationFields.count,
              expectationFieldSet.isSubset(of: operation.allowedExpectationFields),
              expectationFieldSet.isSuperset(of: operation.requiredExpectationFields(for: payload))
        else {
            throw CustomerIntelligenceError.invalidProposal
        }
        let valid: Bool = switch operation {
        case .createOrganization:
            normalizedText(payload.name) != nil
                && (payload.nodeKind == "organization" || payload.nodeKind == "unit")
                && (payload.nodeKind != "unit"
                    || payload.parentOrganizationID != nil
                    || payload.parentOrganizationLocalKey != nil)
        case .renameOrganization:
            payload.targetID != nil && normalizedText(payload.name) != nil
        case .moveOrganization:
            payload.targetID != nil
        case .createProvisionalContact:
            normalizedText(payload.name) != nil
        case .renameProvisionalContact:
            payload.targetID != nil && normalizedText(payload.name) != nil
        case .resolveProvisionalContact:
            payload.targetID != nil && CustomerIdentityNormalizer.email(payload.email ?? "") != nil
        case .setMembership, .removeMembership:
            (payload.organizationID != nil || payload.organizationLocalKey != nil)
                && (payload.contactID != nil || payload.contactLocalKey != nil)
        case .createTopic:
            normalizedText(payload.title) != nil && normalizedText(payload.currentState) != nil
        case .updateTopic:
            payload.targetID != nil
                && (normalizedText(payload.title) != nil || normalizedText(payload.currentState) != nil)
        case .setTopicReferences:
            payload.targetID != nil && payload.references != nil
        }
        guard valid else { throw CustomerIntelligenceError.invalidProposal }
    }

    private nonisolated static func proposalApplyOrder(
        proposals: [CustomerIntelligenceProposalRecord],
        selected: Set<UUID>,
        in db: Database
    ) throws -> [CustomerIntelligenceProposalRecord] {
        var dependencies: [UUID: Set<UUID>] = [:]
        for proposal in proposals {
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT dependencies.requiredProposalId, required.status
                FROM customer_intelligence_proposal_dependencies AS dependencies
                JOIN customer_intelligence_proposals AS required
                  ON required.id = dependencies.requiredProposalId
                WHERE dependencies.proposalId = ?
                """,
                arguments: [proposal.id]
            )
            var selectedDependencies = Set<UUID>()
            for row in rows {
                let requiredID: UUID = row["requiredProposalId"]
                let status: String = row["status"]
                guard status == CustomerIntelligenceProposalStatus.applied.rawValue || selected.contains(requiredID) else {
                    throw CustomerIntelligenceError.proposalDependency
                }
                if selected.contains(requiredID) {
                    selectedDependencies.insert(requiredID)
                }
            }
            dependencies[proposal.id] = selectedDependencies
        }
        let proposalsByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
        var remaining = dependencies
        var order: [CustomerIntelligenceProposalRecord] = []
        while !remaining.isEmpty {
            let ready = remaining.filter(\.value.isEmpty).map(\.key).sorted { $0.uuidString < $1.uuidString }
            guard !ready.isEmpty else { throw CustomerIntelligenceError.proposalCycle }
            for id in ready {
                guard let proposal = proposalsByID[id] else {
                    throw CustomerIntelligenceError.proposalNotFound
                }
                order.append(proposal)
                remaining.removeValue(forKey: id)
                for key in remaining.keys {
                    remaining[key]?.remove(id)
                }
            }
        }
        return order
    }

    private nonisolated static func rejectContactResolutionCollisions(
        _ proposals: [CustomerIntelligenceProposalRecord],
        payloads: [UUID: (operationType: String, payloadJSON: String, payload: CustomerIntelligenceProposalPayload)]
    ) throws {
        let decoded = try proposals.map { proposal in
            guard let prepared = payloads[proposal.id] else {
                throw CustomerIntelligenceError.proposalConflict
            }
            return (prepared.operationType, prepared.payload)
        }
        let resolved = Set(decoded.compactMap { type, payload in
            type == CustomerIntelligenceProposalOperationType.resolveProvisionalContact.rawValue ? payload.targetID : nil
        })
        guard decoded.allSatisfy({ type, payload in
            type == CustomerIntelligenceProposalOperationType.resolveProvisionalContact.rawValue
                || resolved.isDisjoint(with: payload.referencedIDs)
        }) else {
            throw CustomerIntelligenceError.proposalConflict
        }
    }

    private nonisolated static func validateExpectations(
        operationType: String,
        payload: CustomerIntelligenceProposalPayload,
        vaultId: UUID,
        in db: Database
    ) throws {
        guard let operation = CustomerIntelligenceProposalOperationType(rawValue: operationType) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        switch operation {
        case .createOrganization, .createProvisionalContact, .createTopic:
            if let targetID = payload.targetID,
               try resourceExists(targetID, in: db) {
                throw CustomerIntelligenceError.proposalConflict
            }
        case .renameOrganization, .moveOrganization:
            guard let id = payload.targetID,
                  let organization = try OrganizationRecord
                  .filter(Column("id") == id && Column("vaultId") == vaultId)
                  .fetchOne(db)
            else { throw CustomerIntelligenceError.organizationNotFound }
            try match(payload, field: "name", actual: organization.name)
            try match(payload, field: "parent_organization_id", actual: organization.parentOrganizationId?.uuidString)
        case .renameProvisionalContact, .resolveProvisionalContact:
            guard let id = payload.targetID,
                  let contact = try ContactRecord
                  .filter(Column("id") == id && Column("vaultId") == vaultId)
                  .fetchOne(db),
                  contact.isProvisional
            else { throw CustomerIntelligenceError.provisionalContactRequired }
            try match(payload, field: "display_name", actual: contact.displayName)
            try match(payload, field: "email", actual: contact.email)
        case .setMembership, .removeMembership:
            guard let organizationID = payload.organizationID, let contactID = payload.contactID,
                  try OrganizationRecord
                  .filter(Column("id") == organizationID && Column("vaultId") == vaultId)
                  .fetchOne(db) != nil,
                  try ContactRecord
                  .filter(Column("id") == contactID && Column("vaultId") == vaultId)
                  .fetchOne(db) != nil
            else { throw CustomerIntelligenceError.proposalConflict }
            let role = try String.fetchOne(
                db,
                sql: """
                SELECT roleLabel FROM organization_memberships
                WHERE organizationId = ? AND contactId = ?
                """,
                arguments: [organizationID, contactID]
            )
            try match(payload, field: "role_label", actual: role)
        case .updateTopic, .setTopicReferences:
            guard let id = payload.targetID,
                  let topic = try ConversationTopicRecord
                  .filter(Column("id") == id && Column("vaultId") == vaultId)
                  .fetchOne(db)
            else { throw CustomerIntelligenceError.topicNotFound }
            try match(payload, field: "title", actual: topic.title)
            try match(payload, field: "current_state", actual: topic.currentState)
            if payload.expectation(for: "references") != nil {
                try match(payload, field: "references", actual: topicReferenceSignature(id, in: db))
            }
        }
    }

    private nonisolated static func match(
        _ payload: CustomerIntelligenceProposalPayload,
        field: String,
        actual: String?
    ) throws {
        guard let expectation = payload.expectation(for: field) else { return }
        guard expectation.value == actual else { throw CustomerIntelligenceError.proposalConflict }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private nonisolated static func apply(
        proposalID: UUID,
        operationType: String,
        payload: CustomerIntelligenceProposalPayload,
        vaultId: UUID,
        now: Date,
        in db: Database
    ) throws {
        guard let operation = CustomerIntelligenceProposalOperationType(rawValue: operationType) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        switch operation {
        case .createOrganization:
            guard let id = payload.targetID,
                  let kind = payload.nodeKind.flatMap(OrganizationNodeKind.init(rawValue:)),
                  let name = normalizedText(payload.name)
            else { throw CustomerIntelligenceError.invalidProposal }
            try OrganizationRecord(
                id: id,
                vaultId: vaultId,
                parentOrganizationId: payload.parentOrganizationID,
                nodeKind: kind,
                name: name,
                revision: 1,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        case .renameOrganization:
            guard let id = payload.targetID, let name = normalizedText(payload.name),
                  var organization = try OrganizationRecord.fetchOne(db, key: id)
            else { throw CustomerIntelligenceError.invalidProposal }
            organization.name = name
            organization.revision += 1
            organization.updatedAt = now
            try organization.update(db)
        case .moveOrganization:
            guard let id = payload.targetID,
                  var organization = try OrganizationRecord.fetchOne(db, key: id)
            else { throw CustomerIntelligenceError.invalidProposal }
            organization.parentOrganizationId = payload.parentOrganizationID
            organization.revision += 1
            organization.updatedAt = now
            try organization.update(db)
        case .createProvisionalContact:
            guard let id = payload.targetID, let name = payload.name else {
                throw CustomerIntelligenceError.invalidProposal
            }
            _ = try createProvisionalContact(id: id, vaultId: vaultId, displayName: name, now: now, in: db)
        case .renameProvisionalContact:
            guard let id = payload.targetID, let name = normalizedText(payload.name),
                  var contact = try ContactRecord.fetchOne(db, key: id), contact.isProvisional
            else { throw CustomerIntelligenceError.provisionalContactRequired }
            contact.displayName = name
            contact.revision += 1
            contact.updatedAt = now
            try contact.update(db)
        case .resolveProvisionalContact:
            guard let id = payload.targetID, let email = payload.email else {
                throw CustomerIntelligenceError.invalidProposal
            }
            _ = try resolveProvisionalContact(
                id: id,
                vaultId: vaultId,
                email: email,
                currentProposalID: proposalID,
                now: now,
                in: db
            )
        case .setMembership:
            guard let organizationID = payload.organizationID, let contactID = payload.contactID else {
                throw CustomerIntelligenceError.invalidProposal
            }
            try db.execute(
                sql: """
                INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (organizationId, contactId)
                DO UPDATE SET roleLabel = excluded.roleLabel
                """,
                arguments: [organizationID, contactID, normalizedText(payload.roleLabel), now]
            )
        case .removeMembership:
            try db.execute(
                sql: """
                DELETE FROM organization_memberships
                WHERE organizationId = ? AND contactId = ?
                """,
                arguments: [payload.organizationID, payload.contactID]
            )
        case .createTopic:
            guard let id = payload.targetID, let title = payload.title, let state = payload.currentState else {
                throw CustomerIntelligenceError.invalidProposal
            }
            _ = try createTopic(
                id: id,
                vaultId: vaultId,
                title: title,
                currentState: state,
                references: payload.references ?? [],
                now: now,
                in: db
            )
        case .updateTopic:
            guard let id = payload.targetID,
                  var topic = try ConversationTopicRecord.fetchOne(db, key: id)
            else { throw CustomerIntelligenceError.topicNotFound }
            if let title = normalizedText(payload.title) { topic.title = title }
            if let state = normalizedText(payload.currentState) { topic.currentState = state }
            topic.revision += 1
            topic.updatedAt = now
            try topic.update(db)
        case .setTopicReferences:
            guard let id = payload.targetID, let references = payload.references else {
                throw CustomerIntelligenceError.invalidProposal
            }
            try replaceTopicReferences(topicId: id, references: references, now: now, in: db)
        }
    }

    // MARK: - Contact correction and deletion

    private nonisolated static func resolveProvisionalContact(
        id: UUID,
        vaultId: UUID,
        email rawEmail: String,
        currentProposalID: UUID,
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
            try markProposalsStale(
                vaultId: vaultId,
                referencing: [id],
                reason: "contactResolved",
                now: now,
                excludingProposalID: currentProposalID,
                in: db
            )
            return provisional
        }
        if existing.displayName == nil, let provisionalName = provisional.displayName {
            existing.displayName = provisionalName
            existing.revision += 1
            existing.updatedAt = now
            try existing.update(db)
        }
        try moveContactReferences(from: id, to: existing.id, now: now, in: db)
        try markProposalsStale(
            vaultId: vaultId,
            referencing: [id],
            reason: "contactResolved",
            now: now,
            excludingProposalID: currentProposalID,
            in: db
        )
        _ = try ContactRecord.deleteOne(db, key: id)
        return existing
    }

    private nonisolated static func moveContactReferences(
        from sourceID: UUID,
        to targetID: UUID,
        now: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
            SELECT organizationId, ?, roleLabel, createdAt
            FROM organization_memberships WHERE contactId = ?;
            DELETE FROM organization_memberships WHERE contactId = ?;

            INSERT OR IGNORE INTO meeting_participants
                (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
            SELECT meetingId, ?, role, responseStatus, source, createdAt, updatedAt
            FROM meeting_participants WHERE contactId = ?;
            DELETE FROM meeting_participants WHERE contactId = ?;

            UPDATE OR IGNORE project_resource_references
            SET resourceId = ?, updatedAt = ?
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM project_resource_references WHERE resourceType = 'contact' AND resourceId = ?;

            INSERT OR IGNORE INTO insight_references
                (insightId, resourceType, resourceId, referenceRole, createdAt)
            SELECT insightId, resourceType, ?, referenceRole, createdAt
            FROM insight_references WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM insight_references WHERE resourceType = 'contact' AND resourceId = ?;

            INSERT OR IGNORE INTO glossary_term_references
                (glossaryTermId, resourceType, resourceId, createdAt)
            SELECT glossaryTermId, resourceType, ?, createdAt
            FROM glossary_term_references WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM glossary_term_references WHERE resourceType = 'contact' AND resourceId = ?;

            INSERT OR IGNORE INTO conversation_topic_references
                (topicId, resourceType, resourceId, note, createdAt, updatedAt)
            SELECT topicId, resourceType, ?, note, createdAt, ?
            FROM conversation_topic_references WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM conversation_topic_references WHERE resourceType = 'contact' AND resourceId = ?;

            INSERT OR IGNORE INTO customer_intelligence_proposal_evidence
                (proposalId, resourceType, resourceId, note, createdAt)
            SELECT proposalId, resourceType, ?, note, createdAt
            FROM customer_intelligence_proposal_evidence WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM customer_intelligence_proposal_evidence
            WHERE resourceType = 'contact' AND resourceId = ?;
            """,
            arguments: [
                targetID, sourceID, sourceID,
                targetID, sourceID, sourceID,
                targetID, now, sourceID, sourceID,
                targetID, sourceID, sourceID,
                targetID, sourceID, sourceID,
                targetID, now, sourceID, sourceID,
                targetID, sourceID, sourceID,
            ]
        )
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
            glossaryTerms: count(
                "glossary_term_references",
                where: "resourceType = 'contact' AND resourceId = ?"
            ),
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
                   AND resourceId IN (SELECT id FROM subtree)) AS topics
            """,
            arguments: [id, vaultId, vaultId]
        )
        return OrganizationDeletionImpact(
            organizationCount: row?["organizationCount"] ?? 0,
            memberships: row?["memberships"] ?? 0,
            projects: row?["projects"] ?? 0,
            topics: row?["topics"] ?? 0
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
        guard CustomerIntelligenceProposalLimits.containsTopicReferences(references) else {
            throw CustomerIntelligenceError.invalidProposal
        }
        _ = try ConversationTopicReferenceRecord
            .filter(Column("topicId") == topicId)
            .deleteAll(db)
        for reference in references {
            guard let type = ConversationTopicResourceType(rawValue: reference.resourceType.rawValue) else {
                throw CustomerIntelligenceError.invalidProposal
            }
            guard let resourceID = reference.resourceID else {
                throw CustomerIntelligenceError.invalidProposal
            }
            let note = normalizedText(reference.note)
            guard type != .meeting || note != nil else {
                throw CustomerIntelligenceError.invalidProposal
            }
            try ConversationTopicReferenceRecord(
                topicId: topicId,
                resourceType: type,
                resourceId: resourceID,
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

    nonisolated static func markProposalsStale(
        vaultId: UUID,
        referencing ids: Set<UUID>,
        reason: String,
        now: Date,
        excludingProposalID: UUID? = nil,
        in db: Database
    ) throws {
        let proposals = try CustomerIntelligenceProposalRecord
            .filter(Column("vaultId") == vaultId && Column("status") == CustomerIntelligenceProposalStatus.proposed)
            .fetchAll(db)
        for var proposal in proposals {
            if proposal.id == excludingProposalID { continue }
            let payload = try decodePayload(proposal.payloadJSON)
            guard !ids.isDisjoint(with: payload.referencedIDs) else { continue }
            proposal.status = .stale
            proposal.staleReason = reason
            proposal.revision += 1
            proposal.updatedAt = now
            try proposal.update(db)
        }
    }

    private nonisolated static func topicReferenceSignature(_ topicID: UUID, in db: Database) throws -> String {
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

    private nonisolated static func resourceExists(_ id: UUID, in db: Database) throws -> Bool {
        let tables = ["organizations", "contacts", "conversation_topics"]
        for table in tables where try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM \(table) WHERE id = ? LIMIT 1",
            arguments: [id]
        ) != nil {
            return true
        }
        return false
    }

    private nonisolated static func encodePayload(_ payload: CustomerIntelligenceProposalPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(payload), as: UTF8.self)
    }

    private nonisolated static func decodePayload(_ value: String) throws -> CustomerIntelligenceProposalPayload {
        do {
            return try JSONDecoder().decode(
                CustomerIntelligenceProposalPayload.self,
                from: Data(value.utf8)
            )
        } catch {
            throw CustomerIntelligenceError.invalidProposal
        }
    }

    private nonisolated static func createsEntity(_ operation: CustomerIntelligenceProposalOperationType) -> Bool {
        switch operation {
        case .createOrganization, .createProvisionalContact, .createTopic:
            true
        default:
            false
        }
    }

    private nonisolated static func createdResourceKind(
        _ operation: CustomerIntelligenceProposalOperationType
    ) -> CustomerIntelligenceResourceKind? {
        switch operation {
        case .createOrganization: .organization
        case .createProvisionalContact: .contact
        case .createTopic: .topic
        default: nil
        }
    }

    private nonisolated static func validateProposalResources(
        operation: CustomerIntelligenceProposalOperationType,
        payload: CustomerIntelligenceProposalPayload,
        vaultId: UUID,
        newEntityKinds: [UUID: CustomerIntelligenceResourceKind],
        in db: Database
    ) throws {
        var resources: [(CustomerIntelligenceResourceKind, UUID)] = []
        func append(_ kind: CustomerIntelligenceResourceKind, _ id: UUID?) {
            if let id { resources.append((kind, id)) }
        }

        switch operation {
        case .createOrganization:
            append(.organization, payload.parentOrganizationID)
        case .renameOrganization:
            append(.organization, payload.targetID)
        case .moveOrganization:
            append(.organization, payload.targetID)
            append(.organization, payload.parentOrganizationID)
        case .createProvisionalContact:
            break
        case .renameProvisionalContact, .resolveProvisionalContact:
            append(.contact, payload.targetID)
        case .setMembership, .removeMembership:
            append(.organization, payload.organizationID)
            append(.contact, payload.contactID)
        case .createTopic:
            break
        case .updateTopic, .setTopicReferences:
            append(.topic, payload.targetID)
        }

        for reference in payload.references ?? [] {
            guard reference.resourceType != .topic else {
                throw CustomerIntelligenceError.invalidProposal
            }
            append(reference.resourceType, reference.resourceID)
        }
        for (kind, id) in resources {
            if let newKind = newEntityKinds[id] {
                guard newKind == kind else { throw CustomerIntelligenceError.invalidProposal }
                continue
            }
            guard try resource(kind, id: id, existsIn: vaultId, in: db) else {
                throw CustomerIntelligenceError.invalidProposal
            }
        }
    }

    private nonisolated static func resource(
        _ kind: CustomerIntelligenceResourceKind,
        id: UUID,
        existsIn vaultId: UUID,
        in db: Database
    ) throws -> Bool {
        let table = switch kind {
        case .organization: "organizations"
        case .contact: "contacts"
        case .project: "projects"
        case .meeting: "meetings"
        case .topic: "conversation_topics"
        }
        return try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM \(table) WHERE id = ? AND vaultId = ? LIMIT 1",
            arguments: [id, vaultId]
        ) != nil
    }

    private nonisolated static func resolveLocalReferences(
        in payload: inout CustomerIntelligenceProposalPayload,
        entityIDs: [String: UUID]
    ) throws {
        if let key = payload.parentOrganizationLocalKey {
            guard let id = entityIDs[key] else { throw CustomerIntelligenceError.invalidProposal }
            payload.parentOrganizationID = id
            payload.parentOrganizationLocalKey = nil
        }
        if let key = payload.organizationLocalKey {
            guard let id = entityIDs[key] else { throw CustomerIntelligenceError.invalidProposal }
            payload.organizationID = id
            payload.organizationLocalKey = nil
        }
        if let key = payload.contactLocalKey {
            guard let id = entityIDs[key] else { throw CustomerIntelligenceError.invalidProposal }
            payload.contactID = id
            payload.contactLocalKey = nil
        }
        if var references = payload.references {
            for index in references.indices {
                if let key = references[index].resourceLocalKey {
                    guard let id = entityIDs[key] else { throw CustomerIntelligenceError.invalidProposal }
                    references[index].resourceID = id
                    references[index].resourceLocalKey = nil
                }
            }
            payload.references = references
        }
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
