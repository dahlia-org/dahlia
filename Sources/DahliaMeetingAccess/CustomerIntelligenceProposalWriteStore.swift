import DahliaRuntimeSupport
import Foundation
import GRDB

public extension MeetingAccessStore {
    func proposeCustomerIntelligenceChanges(
        _ inputs: [CustomerIntelligenceProposalInput]
    ) throws -> CustomerIntelligenceProposalCreationResult {
        try requireCustomerIntelligenceWriteAccess()
        let ordered = try validateProposalInputs(inputs)
        let vault = try scopedVault()
        let proposalIDs: [String: UUID] = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0.localKey, customerIntelligenceUUIDv7()) }
        )
        let entityIDs = Dictionary(uniqueKeysWithValues: ordered.compactMap { input -> (String, UUID)? in
            createsEntity(input.operationType)
                ? (input.localKey, customerIntelligenceUUIDv7())
                : nil
        })
        let newEntityKinds: [UUID: CustomerIntelligenceResourceKind] = Dictionary(
            uniqueKeysWithValues: ordered.compactMap { input -> (UUID, CustomerIntelligenceResourceKind)? in
                guard let id = entityIDs[input.localKey],
                      let kind = createdResourceKind(input.operationType) else { return nil }
                return (id, kind)
            }
        )
        try database.write { db in
            let now = Date.now
            for input in ordered {
                guard let proposalID = proposalIDs[input.localKey] else {
                    throw MeetingAccessError.invalidProposal
                }
                var payload = input.payload
                if let entityID = entityIDs[input.localKey] { payload.targetID = entityID }
                try resolveLocalReferences(in: &payload, entityIDs: entityIDs)
                guard payload.references.map(CustomerIntelligenceProposalLimits.containsTopicReferences) ?? true
                else {
                    throw MeetingAccessError.invalidProposal
                }
                try validateProposalResources(
                    operation: input.operationType,
                    payload: payload,
                    newEntityKinds: newEntityKinds,
                    in: db
                )
                let payloadData = try JSONEncoder().encode(payload)
                try db.execute(
                    sql: """
                    INSERT INTO customer_intelligence_proposals
                        (id, vaultId, operationType, payloadJSON, status, staleReason, revision, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, 'proposed', NULL, 1, ?, ?)
                    """,
                    arguments: [
                        proposalID,
                        vaultID,
                        input.operationType.rawValue,
                        String(decoding: payloadData, as: UTF8.self),
                        now,
                        now,
                    ]
                )
                for evidence in input.evidence {
                    try validateProposalResource(
                        type: evidence.resourceType,
                        id: evidence.resourceID,
                        vaultID: vaultID,
                        in: db
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO customer_intelligence_proposal_evidence
                            (proposalId, resourceType, resourceId, note, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            proposalID,
                            evidence.resourceType.rawValue,
                            evidence.resourceID,
                            normalizedProposalText(evidence.note),
                            now,
                        ]
                    )
                }
                for key in input.dependsOn {
                    guard let requiredID = proposalIDs[key] else {
                        throw MeetingAccessError.proposalDependency
                    }
                    try db.execute(
                        sql: """
                        INSERT INTO customer_intelligence_proposal_dependencies
                            (proposalId, requiredProposalId, createdAt)
                        VALUES (?, ?, ?)
                        """,
                        arguments: [proposalID, requiredID, now]
                    )
                }
            }
        }
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
        return CustomerIntelligenceProposalCreationResult(
            vault: vault,
            proposalIDsByLocalKey: proposalIDs,
            entityIDsByLocalKey: entityIDs
        )
    }

    func rejectCustomerIntelligenceProposals(
        _ revisions: [UUID: Int]
    ) throws -> CustomerIntelligenceProposalMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard (1 ... 100).contains(revisions.count) else { throw MeetingAccessError.invalidProposal }
        let vault = try scopedVault()
        try database.write { db in
            for (id, revision) in revisions {
                try db.execute(
                    sql: """
                    UPDATE customer_intelligence_proposals
                    SET status = 'rejected', staleReason = NULL, revision = revision + 1, updatedAt = ?
                    WHERE id = ? AND vaultId = ? AND status IN ('proposed', 'stale') AND revision = ?
                    """,
                    arguments: [Date.now, id, vaultID, revision]
                )
                guard db.changesCount == 1 else { throw MeetingAccessError.proposalConflict }
            }
        }
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
        return CustomerIntelligenceProposalMutationResult(
            vault: vault,
            proposalIDs: revisions.keys.sorted { $0.uuidString < $1.uuidString }
        )
    }

    func applyCustomerIntelligenceProposals(
        _ revisions: [UUID: Int]
    ) throws -> CustomerIntelligenceProposalMutationResult {
        try requireCustomerIntelligenceWriteAccess()
        guard (1 ... 100).contains(revisions.count) else { throw MeetingAccessError.invalidProposal }
        let vault = try scopedVault()
        let prepared = try database.read { db in
            try Dictionary(
                uniqueKeysWithValues: revisions.keys.map { id in
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT * FROM customer_intelligence_proposals
                        WHERE id = ? AND vaultId = ?
                        """,
                        arguments: [id, vaultID]
                    ) else {
                        throw MeetingAccessError.proposalConflict
                    }
                    let proposal = try proposalWriteRow(row)
                    try validateProposalPayload(proposal.payload, operation: proposal.operation)
                    return (id, proposal)
                }
            )
        }
        try database.write { db in
            let proposals = try revisions.map { id, revision -> ProposalWriteRow in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM customer_intelligence_proposals
                    WHERE id = ? AND vaultId = ?
                    """,
                    arguments: [id, vaultID]
                ), (row["status"] as String) == "proposed", (row["revision"] as Int) == revision
                else {
                    throw MeetingAccessError.proposalConflict
                }
                let payloadJSON: String = row["payloadJSON"]
                let operationType: String = row["operationType"]
                guard let proposal = prepared[id],
                      proposal.payloadJSON == payloadJSON,
                      proposal.operation.rawValue == operationType
                else {
                    throw MeetingAccessError.proposalConflict
                }
                return proposal
            }
            let ordered = try proposalWriteOrder(proposals, selected: Set(revisions.keys), in: db)
            try rejectResolutionCollisions(ordered)

            for proposal in ordered {
                // Each expectation is checked immediately before its canonical write. This
                // keeps dependent proposals valid while detecting same-field batch conflicts.
                try validateProposalExpectations(proposal, in: db)
                try applyProposal(proposal, in: db)
                try db.execute(
                    sql: """
                    UPDATE customer_intelligence_proposals
                    SET status = 'applied', revision = revision + 1, updatedAt = ?
                    WHERE id = ? AND vaultId = ? AND status = 'proposed'
                    """,
                    arguments: [Date.now, proposal.id, vaultID]
                )
                guard db.changesCount == 1 else { throw MeetingAccessError.proposalConflict }
            }
        }
        DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
        return CustomerIntelligenceProposalMutationResult(
            vault: vault,
            proposalIDs: revisions.keys.sorted { $0.uuidString < $1.uuidString }
        )
    }
}

private extension MeetingAccessStore {
    struct ProposalWriteRow {
        let id: UUID
        let operation: CustomerIntelligenceProposalOperationType
        let payloadJSON: String
        let payload: CustomerIntelligenceProposalPayload
    }

    func requireCustomerIntelligenceWriteAccess() throws {
        guard allowsWrites else { throw MeetingAccessError.writeAccessRequired }
    }

    func proposalWriteRow(_ row: Row) throws -> ProposalWriteRow {
        let json: String = row["payloadJSON"]
        guard let operation = CustomerIntelligenceProposalOperationType(rawValue: row["operationType"]),
              let payload = try? JSONDecoder().decode(
                  CustomerIntelligenceProposalPayload.self,
                  from: Data(json.utf8)
              )
        else {
            throw MeetingAccessError.invalidProposal
        }
        return ProposalWriteRow(id: row["id"], operation: operation, payloadJSON: json, payload: payload)
    }

    func validateProposalInputs(
        _ inputs: [CustomerIntelligenceProposalInput]
    ) throws -> [CustomerIntelligenceProposalInput] {
        guard CustomerIntelligenceProposalLimits.containsBatch(inputs) else {
            throw MeetingAccessError.invalidProposal
        }
        let keys = inputs.map(\.localKey)
        let allKeys = Set(keys)
        guard allKeys.count == keys.count,
              keys.allSatisfy({ normalizedProposalText($0) != nil }),
              inputs.allSatisfy({
                  let dependencies = Set($0.dependsOn)
                  return dependencies.isSubset(of: allKeys)
                      && $0.payload.referencedLocalKeys.isSubset(of: dependencies)
              })
        else {
            throw MeetingAccessError.invalidProposal
        }
        let inputsByKey = Dictionary(uniqueKeysWithValues: inputs.map { ($0.localKey, $0) })
        var remaining = Dictionary(uniqueKeysWithValues: inputs.map { ($0.localKey, Set($0.dependsOn)) })
        var result: [CustomerIntelligenceProposalInput] = []
        while !remaining.isEmpty {
            let ready = remaining.filter(\.value.isEmpty).map(\.key).sorted()
            guard !ready.isEmpty else { throw MeetingAccessError.invalidProposal }
            for key in ready {
                guard let input = inputsByKey[key] else {
                    throw MeetingAccessError.invalidProposal
                }
                try validateProposalPayload(input.payload, operation: input.operationType)
                result.append(input)
                remaining.removeValue(forKey: key)
                for other in remaining.keys {
                    remaining[other]?.remove(key)
                }
            }
        }
        return result
    }

    func validateProposalPayload(
        _ payload: CustomerIntelligenceProposalPayload,
        operation: CustomerIntelligenceProposalOperationType
    ) throws {
        guard CustomerIntelligenceProposalLimits.contains(CustomerIntelligenceProposalInput(
            localKey: "stored",
            operationType: operation,
            payload: payload
        )) else {
            throw MeetingAccessError.invalidProposal
        }
        let expectationFields = payload.expectations.map(\.field)
        let expectationFieldSet = Set(expectationFields)
        guard expectationFieldSet.count == expectationFields.count,
              expectationFieldSet.isSubset(of: operation.allowedExpectationFields),
              expectationFieldSet.isSuperset(of: operation.requiredExpectationFields(for: payload))
        else {
            throw MeetingAccessError.invalidProposal
        }
        let isValid: Bool = switch operation {
        case .createOrganization:
            normalizedProposalText(payload.name) != nil
                && (payload.nodeKind == "organization" || payload.nodeKind == "unit")
                && (payload.nodeKind != "unit"
                    || payload.parentOrganizationID != nil
                    || payload.parentOrganizationLocalKey != nil)
        case .renameOrganization:
            payload.targetID != nil && normalizedProposalText(payload.name) != nil
        case .moveOrganization:
            payload.targetID != nil
        case .createProvisionalContact:
            normalizedProposalText(payload.name) != nil
        case .renameProvisionalContact:
            payload.targetID != nil && normalizedProposalText(payload.name) != nil
        case .resolveProvisionalContact:
            payload.targetID != nil && normalizedEmail(payload.email) != nil
        case .setMembership, .removeMembership:
            (payload.organizationID != nil || payload.organizationLocalKey != nil)
                && (payload.contactID != nil || payload.contactLocalKey != nil)
        case .createTopic:
            normalizedProposalText(payload.title) != nil && normalizedProposalText(payload.currentState) != nil
        case .updateTopic:
            payload.targetID != nil
                && (normalizedProposalText(payload.title) != nil
                    || normalizedProposalText(payload.currentState) != nil)
        case .setTopicReferences:
            payload.targetID != nil && payload.references != nil
        }
        guard isValid else { throw MeetingAccessError.invalidProposal }
    }

    func resolveLocalReferences(
        in payload: inout CustomerIntelligenceProposalPayload,
        entityIDs: [String: UUID]
    ) throws {
        if let key = payload.parentOrganizationLocalKey {
            guard let id = entityIDs[key] else { throw MeetingAccessError.invalidProposal }
            payload.parentOrganizationID = id
            payload.parentOrganizationLocalKey = nil
        }
        if let key = payload.organizationLocalKey {
            guard let id = entityIDs[key] else { throw MeetingAccessError.invalidProposal }
            payload.organizationID = id
            payload.organizationLocalKey = nil
        }
        if let key = payload.contactLocalKey {
            guard let id = entityIDs[key] else { throw MeetingAccessError.invalidProposal }
            payload.contactID = id
            payload.contactLocalKey = nil
        }
        if var references = payload.references {
            for index in references.indices {
                if let key = references[index].resourceLocalKey {
                    guard let id = entityIDs[key] else { throw MeetingAccessError.invalidProposal }
                    references[index].resourceID = id
                    references[index].resourceLocalKey = nil
                }
                guard references[index].resourceID != nil else {
                    throw MeetingAccessError.invalidProposal
                }
            }
            payload.references = references
        }
    }

    func proposalWriteOrder(
        _ proposals: [ProposalWriteRow],
        selected: Set<UUID>,
        in db: Database
    ) throws -> [ProposalWriteRow] {
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
            var selectedRequirements = Set<UUID>()
            for row in rows {
                let requiredID: UUID = row["requiredProposalId"]
                let status: String = row["status"]
                guard status == "applied" || selected.contains(requiredID) else {
                    throw MeetingAccessError.proposalDependency
                }
                if selected.contains(requiredID) { selectedRequirements.insert(requiredID) }
            }
            dependencies[proposal.id] = selectedRequirements
        }
        let proposalsByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
        var remaining = dependencies
        var result: [ProposalWriteRow] = []
        while !remaining.isEmpty {
            let ready = remaining.filter(\.value.isEmpty).map(\.key).sorted { $0.uuidString < $1.uuidString }
            guard !ready.isEmpty else { throw MeetingAccessError.proposalDependency }
            for id in ready {
                guard let proposal = proposalsByID[id] else {
                    throw MeetingAccessError.proposalDependency
                }
                result.append(proposal)
                remaining.removeValue(forKey: id)
                for other in remaining.keys {
                    remaining[other]?.remove(id)
                }
            }
        }
        return result
    }

    func rejectResolutionCollisions(_ proposals: [ProposalWriteRow]) throws {
        let resolved = Set(proposals.compactMap {
            $0.operation == .resolveProvisionalContact ? $0.payload.targetID : nil
        })
        guard proposals.allSatisfy({
            $0.operation == .resolveProvisionalContact
                || resolved.isDisjoint(with: $0.payload.referencedIDs)
        }) else {
            throw MeetingAccessError.proposalConflict
        }
    }

    func validateProposalExpectations(_ proposal: ProposalWriteRow, in db: Database) throws {
        switch proposal.operation {
        case .createOrganization, .createProvisionalContact, .createTopic:
            guard let targetID = proposal.payload.targetID else { throw MeetingAccessError.invalidProposal }
            let exists = try ["organizations", "contacts", "conversation_topics"].contains { table in
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM \(table) WHERE id = ? LIMIT 1",
                    arguments: [targetID]
                ) != nil
            }
            guard !exists else { throw MeetingAccessError.proposalConflict }
        case .renameOrganization, .moveOrganization:
            guard let id = proposal.payload.targetID,
                  let row = try Row.fetchOne(
                      db,
                      sql: "SELECT name, parentOrganizationId FROM organizations WHERE id = ? AND vaultId = ?",
                      arguments: [id, vaultID]
                  )
            else { throw MeetingAccessError.proposalConflict }
            try matchExpectation(proposal.payload, field: "name", actual: row["name"])
            let parent: UUID? = row["parentOrganizationId"]
            try matchExpectation(proposal.payload, field: "parent_organization_id", actual: parent?.uuidString)
        case .renameProvisionalContact, .resolveProvisionalContact:
            guard let id = proposal.payload.targetID,
                  let row = try Row.fetchOne(
                      db,
                      sql: "SELECT email, displayName FROM contacts WHERE id = ? AND vaultId = ?",
                      arguments: [id, vaultID]
                  ), (row["email"] as String?) == nil
            else { throw MeetingAccessError.proposalConflict }
            try matchExpectation(proposal.payload, field: "display_name", actual: row["displayName"])
            try matchExpectation(proposal.payload, field: "email", actual: nil)
        case .setMembership, .removeMembership:
            guard let organizationID = proposal.payload.organizationID,
                  let contactID = proposal.payload.contactID
            else { throw MeetingAccessError.invalidProposal }
            let role = try String.fetchOne(
                db,
                sql: "SELECT roleLabel FROM organization_memberships WHERE organizationId = ? AND contactId = ?",
                arguments: [organizationID, contactID]
            )
            try matchExpectation(proposal.payload, field: "role_label", actual: role)
        case .updateTopic, .setTopicReferences:
            guard let id = proposal.payload.targetID,
                  let row = try Row.fetchOne(
                      db,
                      sql: "SELECT title, currentState FROM conversation_topics WHERE id = ? AND vaultId = ?",
                      arguments: [id, vaultID]
                  )
            else { throw MeetingAccessError.proposalConflict }
            try matchExpectation(proposal.payload, field: "title", actual: row["title"])
            try matchExpectation(proposal.payload, field: "current_state", actual: row["currentState"])
            if proposal.payload.expectation(for: "references") != nil {
                let signature = try topicReferenceSignature(id, in: db)
                try matchExpectation(proposal.payload, field: "references", actual: signature)
            }
        }
    }

    func matchExpectation(
        _ payload: CustomerIntelligenceProposalPayload,
        field: String,
        actual: String?
    ) throws {
        guard let expectation = payload.expectation(for: field) else { return }
        guard expectation.value == actual else { throw MeetingAccessError.proposalConflict }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func applyProposal(_ proposal: ProposalWriteRow, in db: Database) throws {
        let payload = proposal.payload
        let now = Date.now
        switch proposal.operation {
        case .createOrganization:
            guard let id = payload.targetID, let name = normalizedProposalText(payload.name),
                  payload.nodeKind == "organization" || payload.nodeKind == "unit"
            else { throw MeetingAccessError.invalidProposal }
            try db.execute(
                sql: """
                INSERT INTO organizations
                    (id, vaultId, parentOrganizationId, nodeKind, name, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, payload.parentOrganizationID, payload.nodeKind, name, now, now]
            )
        case .renameOrganization:
            guard let id = payload.targetID, let name = normalizedProposalText(payload.name) else {
                throw MeetingAccessError.invalidProposal
            }
            try db.execute(
                sql: """
                UPDATE organizations SET name = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [name, now, id, vaultID]
            )
        case .moveOrganization:
            try db.execute(
                sql: """
                UPDATE organizations
                SET parentOrganizationId = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [payload.parentOrganizationID, now, payload.targetID, vaultID]
            )
        case .createProvisionalContact:
            guard let id = payload.targetID, let name = normalizedProposalText(payload.name) else {
                throw MeetingAccessError.invalidProposal
            }
            try db.execute(
                sql: """
                INSERT INTO contacts
                    (id, vaultId, email, displayName, revision, createdAt, updatedAt)
                VALUES (?, ?, NULL, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, name, now, now]
            )
        case .renameProvisionalContact:
            guard let id = payload.targetID, let name = normalizedProposalText(payload.name) else {
                throw MeetingAccessError.invalidProposal
            }
            try db.execute(
                sql: """
                UPDATE contacts SET displayName = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND email IS NULL
                """,
                arguments: [name, now, id, vaultID]
            )
        case .resolveProvisionalContact:
            try applyContactResolution(
                payload,
                currentProposalID: proposal.id,
                now: now,
                in: db
            )
        case .setMembership:
            try db.execute(
                sql: """
                INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (organizationId, contactId) DO UPDATE SET roleLabel = excluded.roleLabel
                """,
                arguments: [
                    payload.organizationID,
                    payload.contactID,
                    normalizedProposalText(payload.roleLabel),
                    now,
                ]
            )
        case .removeMembership:
            try db.execute(
                sql: "DELETE FROM organization_memberships WHERE organizationId = ? AND contactId = ?",
                arguments: [payload.organizationID, payload.contactID]
            )
        case .createTopic:
            guard let id = payload.targetID, let title = normalizedProposalText(payload.title),
                  let state = normalizedProposalText(payload.currentState)
            else { throw MeetingAccessError.invalidProposal }
            try db.execute(
                sql: """
                INSERT INTO conversation_topics
                    (id, vaultId, title, currentState, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, 1, ?, ?)
                """,
                arguments: [id, vaultID, title, state, now, now]
            )
            try replaceTopicReferences(id, references: payload.references ?? [], now: now, in: db)
        case .updateTopic:
            guard let id = payload.targetID else { throw MeetingAccessError.invalidProposal }
            if let title = normalizedProposalText(payload.title) {
                try db.execute(
                    sql: """
                    UPDATE conversation_topics
                    SET title = ?, revision = revision + 1, updatedAt = ?
                    WHERE id = ? AND vaultId = ?
                    """,
                    arguments: [title, now, id, vaultID]
                )
            }
            if let state = normalizedProposalText(payload.currentState) {
                try db.execute(
                    sql: """
                    UPDATE conversation_topics
                    SET currentState = ?, revision = revision + 1, updatedAt = ?
                    WHERE id = ? AND vaultId = ?
                    """,
                    arguments: [state, now, id, vaultID]
                )
            }
        case .setTopicReferences:
            guard let id = payload.targetID, let references = payload.references else {
                throw MeetingAccessError.invalidProposal
            }
            try replaceTopicReferences(id, references: references, now: now, in: db)
        }
    }

    func applyContactResolution(
        _ payload: CustomerIntelligenceProposalPayload,
        currentProposalID: UUID,
        now: Date,
        in db: Database
    ) throws {
        guard let sourceID = payload.targetID, let email = normalizedEmail(payload.email) else {
            throw MeetingAccessError.invalidProposal
        }
        let existingID = try UUID.fetchOne(
            db,
            sql: "SELECT id FROM contacts WHERE vaultId = ? AND email = ?",
            arguments: [vaultID, email]
        )
        guard let targetID = existingID else {
            try db.execute(
                sql: """
                UPDATE contacts SET email = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ? AND vaultId = ? AND email IS NULL
                """,
                arguments: [email, now, sourceID, vaultID]
            )
            try staleProposals(
                referencing: sourceID,
                reason: "contactResolved",
                excludingProposalID: currentProposalID,
                in: db
            )
            return
        }
        try db.execute(
            sql: """
            UPDATE contacts
            SET displayName = (
                    SELECT displayName FROM contacts AS source WHERE source.id = ?
                ),
                revision = revision + 1,
                updatedAt = ?
            WHERE id = ? AND vaultId = ? AND displayName IS NULL
              AND EXISTS (
                  SELECT 1 FROM contacts AS source
                  WHERE source.id = ? AND source.displayName IS NOT NULL
              )
            """,
            arguments: [sourceID, now, targetID, vaultID, sourceID]
        )
        try moveContactReferences(from: sourceID, to: targetID, now: now, in: db)
        try staleProposals(
            referencing: sourceID,
            reason: "contactResolved",
            excludingProposalID: currentProposalID,
            in: db
        )
        try db.execute(sql: "DELETE FROM contacts WHERE id = ? AND vaultId = ?", arguments: [sourceID, vaultID])
    }

    func moveContactReferences(from source: UUID, to target: UUID, now: Date, in db: Database) throws {
        let moves = [
            """
            INSERT OR IGNORE INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
            SELECT organizationId, ?, roleLabel, createdAt FROM organization_memberships WHERE contactId = ?;
            DELETE FROM organization_memberships WHERE contactId = ?;
            """,
            """
            INSERT OR IGNORE INTO meeting_participants
                (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
            SELECT meetingId, ?, role, responseStatus, source, createdAt, updatedAt
            FROM meeting_participants WHERE contactId = ?;
            DELETE FROM meeting_participants WHERE contactId = ?;
            """,
            """
            UPDATE OR IGNORE project_resource_references SET resourceId = ?, updatedAt = ?
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM project_resource_references WHERE resourceType = 'contact' AND resourceId = ?;
            """,
            """
            UPDATE OR IGNORE insight_references SET resourceId = ?
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM insight_references WHERE resourceType = 'contact' AND resourceId = ?;
            """,
            """
            UPDATE OR IGNORE glossary_term_references SET resourceId = ?
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM glossary_term_references WHERE resourceType = 'contact' AND resourceId = ?;
            """,
            """
            INSERT OR IGNORE INTO conversation_topic_references
                (topicId, resourceType, resourceId, note, createdAt, updatedAt)
            SELECT topicId, resourceType, ?, note, createdAt, ?
            FROM conversation_topic_references
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM conversation_topic_references WHERE resourceType = 'contact' AND resourceId = ?;
            """,
            """
            UPDATE OR IGNORE customer_intelligence_proposal_evidence SET resourceId = ?
            WHERE resourceType = 'contact' AND resourceId = ?;
            DELETE FROM customer_intelligence_proposal_evidence
            WHERE resourceType = 'contact' AND resourceId = ?;
            """,
        ]
        try db.execute(sql: moves[0], arguments: [target, source, source])
        try db.execute(sql: moves[1], arguments: [target, source, source])
        try db.execute(sql: moves[2], arguments: [target, now, source, source])
        try db.execute(sql: moves[3], arguments: [target, source, source])
        try db.execute(sql: moves[4], arguments: [target, source, source])
        try db.execute(sql: moves[5], arguments: [target, now, source, source])
        try db.execute(sql: moves[6], arguments: [target, source, source])
    }

    func replaceTopicReferences(
        _ topicID: UUID,
        references: [CustomerIntelligenceTopicReferenceInput],
        now: Date,
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM conversation_topic_references WHERE topicId = ?", arguments: [topicID])
        for reference in references {
            guard reference.resourceType != .topic, let resourceID = reference.resourceID else {
                throw MeetingAccessError.invalidProposal
            }
            let note = normalizedProposalText(reference.note)
            guard reference.resourceType != .meeting || note != nil else {
                throw MeetingAccessError.invalidProposal
            }
            try db.execute(
                sql: """
                INSERT INTO conversation_topic_references
                    (topicId, resourceType, resourceId, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    topicID,
                    reference.resourceType.rawValue,
                    resourceID,
                    reference.resourceType == .meeting ? note : nil,
                    now,
                    now,
                ]
            )
        }
    }

    func staleProposals(
        referencing id: UUID,
        reason: String,
        excludingProposalID: UUID?,
        in db: Database
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, operationType, payloadJSON FROM customer_intelligence_proposals
            WHERE vaultId = ? AND status = 'proposed'
            """,
            arguments: [vaultID]
        )
        for row in rows {
            let proposalID: UUID = row["id"]
            if proposalID == excludingProposalID { continue }
            let json: String = row["payloadJSON"]
            guard let payload = try? JSONDecoder().decode(
                CustomerIntelligenceProposalPayload.self,
                from: Data(json.utf8)
            ), payload.referencedIDs.contains(id) else {
                continue
            }
            try db.execute(
                sql: """
                UPDATE customer_intelligence_proposals
                SET status = 'stale', staleReason = ?, revision = revision + 1, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [reason, Date.now, proposalID]
            )
        }
    }

    func topicReferenceSignature(_ topicID: UUID, in db: Database) throws -> String {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT resourceType, resourceId, note
            FROM conversation_topic_references
            WHERE topicId = ? ORDER BY resourceType, resourceId
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

    func validateProposalResource(
        type: CustomerIntelligenceResourceKind,
        id: UUID,
        vaultID: UUID,
        in db: Database
    ) throws {
        let table = switch type {
        case .organization: "organizations"
        case .contact: "contacts"
        case .project: "projects"
        case .meeting: "meetings"
        case .topic: "conversation_topics"
        }
        guard try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM \(table) WHERE id = ? AND vaultId = ? LIMIT 1",
            arguments: [id, vaultID]
        ) != nil else {
            throw MeetingAccessError.invalidProposal
        }
    }

    func validateProposalResources(
        operation: CustomerIntelligenceProposalOperationType,
        payload: CustomerIntelligenceProposalPayload,
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
            guard reference.resourceType != .topic else { throw MeetingAccessError.invalidProposal }
            append(reference.resourceType, reference.resourceID)
        }
        for (kind, id) in resources {
            if let newKind = newEntityKinds[id] {
                guard newKind == kind else { throw MeetingAccessError.invalidProposal }
            } else {
                try validateProposalResource(type: kind, id: id, vaultID: vaultID, in: db)
            }
        }
    }

    func createsEntity(_ operation: CustomerIntelligenceProposalOperationType) -> Bool {
        switch operation {
        case .createOrganization, .createProvisionalContact, .createTopic: true
        default: false
        }
    }

    func createdResourceKind(
        _ operation: CustomerIntelligenceProposalOperationType
    ) -> CustomerIntelligenceResourceKind? {
        switch operation {
        case .createOrganization: .organization
        case .createProvisionalContact: .contact
        case .createTopic: .topic
        default: nil
        }
    }

    func normalizedProposalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedEmail(_ value: String?) -> String? {
        value.flatMap(CustomerIdentityNormalizer.email)
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
