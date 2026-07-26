import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct CustomerIntelligenceWorkspaceTests {
        @Test
        // swiftlint:disable:next function_body_length
        func v26RebuildPreservesContactRelationshipsAndRecreatesTriggers() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v25_customerIntelligence")
            let vault = customerIntelligenceVault(name: "v25")
            let otherVault = customerIntelligenceVault(name: "v25-other")
            let contactID = UUID.v7()
            let organizationID = UUID.v7()
            let otherOrganizationID = UUID.v7()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Customer",
                createdAt: .now,
                projectType: .customer
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Sync",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            let referenceID = UUID.v7()
            let insight = InsightRecord(
                id: .v7(),
                vaultId: vault.id,
                content: "Decision maker",
                reviewState: .accepted,
                metadataJSON: "{}",
                createdAt: .now,
                updatedAt: .now
            )
            let glossary = GlossaryTermRecord(
                id: .v7(),
                vaultId: vault.id,
                term: "Dahlia",
                definition: "Product",
                aliasesJSON: "[]",
                createdAt: .now,
                updatedAt: .now
            )
            try queue.write { db in
                try vault.insert(db)
                try otherVault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try insight.insert(db)
                try glossary.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO contacts (id, vaultId, email, displayName, createdAt, updatedAt)
                    VALUES (?, ?, 'owner@example.com', 'Owner', ?, ?);
                    INSERT INTO organizations
                        (id, vaultId, parentOrganizationId, nodeKind, name, createdAt, updatedAt)
                    VALUES (?, ?, NULL, 'organization', 'Acme', ?, ?);
                    INSERT INTO organizations
                        (id, vaultId, parentOrganizationId, nodeKind, name, createdAt, updatedAt)
                    VALUES (?, ?, NULL, 'organization', 'Other', ?, ?);
                    INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                    VALUES (?, ?, 'Lead', ?);
                    INSERT INTO meeting_participants
                        (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
                    VALUES (?, ?, 'required', 'accepted', 'calendar', ?, ?);
                    INSERT INTO project_resource_references
                        (id, projectId, resourceType, resourceId, relationLabel, createdAt, updatedAt)
                    VALUES (?, ?, 'contact', ?, '', ?, ?);
                    INSERT INTO insight_references
                        (insightId, resourceType, resourceId, referenceRole, createdAt)
                    VALUES (?, 'contact', ?, 'evidence', ?);
                    INSERT INTO glossary_term_references
                        (glossaryTermId, resourceType, resourceId, createdAt)
                    VALUES (?, 'contact', ?, ?);
                    """,
                    arguments: [
                        contactID, vault.id, Date.now, Date.now,
                        organizationID, vault.id, Date.now, Date.now,
                        otherOrganizationID, otherVault.id, Date.now, Date.now,
                        organizationID, contactID, Date.now,
                        meeting.id, contactID, Date.now, Date.now,
                        referenceID, project.id, contactID, Date.now, Date.now,
                        insight.id, contactID, Date.now,
                        glossary.id, contactID, Date.now,
                    ]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db in
                let fetchedContact = try ContactRecord.fetchOne(db, key: contactID)
                let contact = try #require(fetchedContact)
                #expect(contact.email == "owner@example.com")
                #expect(contact.displayName == "Owner")
                #expect(contact.revision >= 1)
                #expect(try OrganizationMembershipRecord.fetchCount(db) == 1)
                #expect(try MeetingParticipantRecord.fetchCount(db) == 1)
                #expect(try ProjectResourceReferenceRecord.fetchCount(db) == 1)
                #expect(try InsightReferenceRecord.fetchCount(db) == 1)
                #expect(try GlossaryTermReferenceRecord.fetchCount(db) == 1)
                let fetchedMembership = try OrganizationMembershipRecord.fetchOne(
                    db,
                    key: ["organizationId": organizationID, "contactId": contactID]
                )
                let membership = try #require(fetchedMembership)
                #expect(membership.roleLabel == "Lead")
                let fetchedParticipant = try MeetingParticipantRecord.fetchOne(
                    db,
                    key: ["meetingId": meeting.id, "contactId": contactID]
                )
                let participant = try #require(fetchedParticipant)
                #expect(participant.role == .required)
                #expect(participant.responseStatus == .accepted)
                #expect(participant.source == "calendar")
                let fetchedProjectReference = try ProjectResourceReferenceRecord.fetchOne(db, key: referenceID)
                let projectReference = try #require(fetchedProjectReference)
                #expect(projectReference.projectId == project.id)
                #expect(projectReference.resourceId == contactID)
                #expect(projectReference.relationLabel.isEmpty)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                let indexes = try Set(String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
                ))
                #expect(indexes.contains("contacts_on_vaultId_sortKey_id"))
                #expect(indexes.contains("meeting_participants_on_contactId_meetingId"))
            }

            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
                        VALUES (?, ?, NULL, ?)
                        """,
                        arguments: [otherOrganizationID, contactID, Date.now]
                    )
                }
            }

            let otherMeeting = MeetingRecord(
                id: .v7(),
                vaultId: otherVault.id,
                projectId: nil,
                name: "Other",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try otherMeeting.insert(db)
                    try MeetingParticipantRecord(
                        meetingId: otherMeeting.id,
                        contactId: contactID,
                        role: .required,
                        responseStatus: .accepted,
                        source: "calendar",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            try queue.write { db in
                try ContactRecord(
                    id: .v7(),
                    vaultId: vault.id,
                    email: nil,
                    displayName: "Provisional One",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try ContactRecord(
                    id: .v7(),
                    vaultId: vault.id,
                    email: nil,
                    displayName: "Provisional Two",
                    revision: 1,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            #expect(throws: DatabaseError.self) {
                try queue.write { db in
                    try ContactRecord(
                        id: .v7(),
                        vaultId: vault.id,
                        email: "owner@example.com",
                        displayName: "Duplicate",
                        revision: 1,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
            }

            try queue.write { db in
                _ = try ContactRecord.deleteOne(db, key: contactID)
                #expect(try ProjectResourceReferenceRecord.fetchCount(db) == 0)
                #expect(try InsightReferenceRecord.fetchCount(db) == 0)
                #expect(try GlossaryTermReferenceRecord.fetchCount(db) == 0)
            }
        }

        @Test
        func topicsDeriveHistoryAndReferencesIncreaseRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let meeting = try fixture.insertMeeting()
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security review",
                currentState: "Questionnaire shared",
                references: [
                    .init(resourceType: .organization, resourceID: organization.id),
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "Owner assigned"),
                ]
            )
            try fixture.repository.replaceConversationTopicReferences(
                topicId: topic.id,
                vaultId: fixture.vault.id,
                expectedRevision: topic.revision,
                references: [
                    .init(resourceType: .organization, resourceID: organization.id),
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "Owner assigned"),
                ]
            )

            let fetchedDetail = try fixture.repository.fetchConversationTopic(
                id: topic.id,
                vaultId: fixture.vault.id
            )
            let detail = try #require(fetchedDetail)
            #expect(detail.0.meetingCount == 1)
            #expect(detail.0.organizationCount == 1)
            #expect(try abs(#require(detail.0.lastDiscussedAt).timeIntervalSince(meeting.createdAt)) < 0.001)
            #expect(detail.0.topic.revision > topic.revision)
            #expect(detail.1.first(where: { $0.resourceType == .meeting })?.note == "Owner assigned")
        }

        @Test
        func proposalEvidenceResourceCanOnlyBeRewrittenForContactResolution() throws {
            let fixture = try CustomerIntelligenceFixture()
            let first = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "First"
            )
            let second = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Second"
            )
            let proposalIDs = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: first.id,
                            name: "Renamed",
                            expectations: [.init(field: "name", value: "First")]
                        ),
                        evidence: [.init(resourceType: .organization, resourceID: first.id)]
                    ),
                ]
            )
            let proposalID = try #require(proposalIDs["rename"])

            #expect(throws: DatabaseError.self) {
                try fixture.manager.dbQueue.write { db in
                    try db.execute(
                        sql: """
                        UPDATE customer_intelligence_proposal_evidence
                        SET resourceId = ?
                        WHERE proposalId = ? AND resourceType = 'organization'
                        """,
                        arguments: [second.id, proposalID]
                    )
                }
            }
        }

        @Test
        func proposalsRequireExpectationsForEveryChangedCanonicalField() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )

            #expect(throws: CustomerIntelligenceError.invalidProposal) {
                try fixture.repository.proposeCustomerIntelligenceChanges(
                    vaultId: fixture.vault.id,
                    inputs: [
                        .init(
                            localKey: "rename",
                            operationType: .renameOrganization,
                            payload: .init(targetID: organization.id, name: "Acme Corp")
                        ),
                    ]
                )
            }
        }

        @Test
        func proposalFieldConflictRollsBackEntireBatch() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Alex"
            )
            let ids = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: organization.id,
                            name: "Acme Corp",
                            expectations: [.init(field: "name", value: "Acme")]
                        )
                    ),
                    .init(
                        localKey: "person",
                        operationType: .renameProvisionalContact,
                        payload: .init(
                            targetID: contact.id,
                            name: "Alex Kim",
                            expectations: [.init(field: "display_name", value: "Someone Else")]
                        )
                    ),
                ]
            )
            let proposals = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                status: .proposed
            )
            let revisions = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0.proposal.revision) })

            #expect(throws: CustomerIntelligenceError.proposalConflict) {
                try fixture.repository.applyCustomerIntelligenceProposals(
                    vaultId: fixture.vault.id,
                    revisions: revisions
                )
            }
            #expect(try fixture.repository.fetchOrganization(
                id: organization.id,
                vaultId: fixture.vault.id
            )?.name == "Acme")
            #expect(Set(ids.values) == Set(revisions.keys))
        }

        @Test
        func resolvingContactMovesEvidenceAndStalesPayloadReferences() throws {
            let fixture = try CustomerIntelligenceFixture()
            let provisional = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Taylor"
            )
            let identified = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "taylor@example.com",
                displayName: "Taylor Identified"
            )
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "dependent",
                        operationType: .renameProvisionalContact,
                        payload: .init(
                            targetID: provisional.id,
                            name: "Taylor R.",
                            expectations: [.init(field: "display_name", value: "Taylor")]
                        )
                    ),
                    .init(
                        localKey: "resolve",
                        operationType: .resolveProvisionalContact,
                        payload: .init(
                            targetID: provisional.id,
                            email: "taylor@example.com",
                            expectations: [.init(field: "email", value: nil)]
                        ),
                        evidence: [.init(resourceType: .contact, resourceID: provisional.id)]
                    ),
                ]
            )
            let proposals = try fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id)
            let resolve = try #require(proposals.first {
                $0.proposal.operationType == CustomerIntelligenceProposalOperationType.resolveProvisionalContact.rawValue
            })
            try fixture.repository.applyCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: [resolve.id: resolve.proposal.revision]
            )

            let after = try fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id)
            #expect(after.first {
                $0.proposal.operationType == CustomerIntelligenceProposalOperationType.renameProvisionalContact.rawValue
            }?.proposal.staleReason == "contactResolved")
            #expect(after.first { $0.id == resolve.id }?.evidence.first?.resourceId == identified.id)
            #expect(try fixture.repository.fetchContact(id: provisional.id, vaultId: fixture.vault.id) == nil)
        }

        @Test
        func resolvingWithUnusedEmailKeepsContactIdentityAndStalesProvisionalOperations() throws {
            let fixture = try CustomerIntelligenceFixture()
            let provisional = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Robin"
            )
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameProvisionalContact,
                        payload: .init(
                            targetID: provisional.id,
                            name: "Robin Lee",
                            expectations: [.init(field: "display_name", value: "Robin")]
                        )
                    ),
                    .init(
                        localKey: "resolve",
                        operationType: .resolveProvisionalContact,
                        payload: .init(
                            targetID: provisional.id,
                            email: "robin@example.com",
                            expectations: [.init(field: "email", value: nil)]
                        )
                    ),
                ]
            )
            let proposals = try fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id)
            let resolve = try #require(proposals.first {
                $0.proposal.operationType == CustomerIntelligenceProposalOperationType.resolveProvisionalContact.rawValue
            })

            try fixture.repository.applyCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: [resolve.id: resolve.proposal.revision]
            )

            let fetchedResolved = try fixture.repository.fetchContact(
                id: provisional.id,
                vaultId: fixture.vault.id
            )
            let resolved = try #require(fetchedResolved)
            #expect(resolved.email == "robin@example.com")
            let after = try fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id)
            #expect(after.first {
                $0.proposal.operationType == CustomerIntelligenceProposalOperationType.renameProvisionalContact.rawValue
            }?.proposal.staleReason == "contactResolved")
        }

        @Test
        func participantMutationsIncreaseTheOwningContactRevision() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@example.com",
                displayName: "Owner"
            )

            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: meeting.id,
                    contactId: contact.id,
                    role: .required,
                    responseStatus: .accepted,
                    source: "calendar",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let fetchedAfterInsert = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterInsert = try #require(fetchedAfterInsert)
            #expect(afterInsert.revision == contact.revision + 1)

            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE meeting_participants
                    SET responseStatus = 'tentative', updatedAt = ?
                    WHERE meetingId = ? AND contactId = ?
                    """,
                    arguments: [Date.now, meeting.id, contact.id]
                )
            }
            let fetchedAfterUpdate = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterUpdate = try #require(fetchedAfterUpdate)
            #expect(afterUpdate.revision == afterInsert.revision + 1)

            try fixture.manager.dbQueue.write { db in
                _ = try MeetingParticipantRecord
                    .filter(Column("meetingId") == meeting.id && Column("contactId") == contact.id)
                    .deleteAll(db)
            }
            let fetchedAfterDelete = try fixture.repository.fetchContact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let afterDelete = try #require(fetchedAfterDelete)
            #expect(afterDelete.revision == afterUpdate.revision + 1)
        }

        @Test
        func unrelatedOrganizationFreshnessDoesNotInvalidateFieldExpectation() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let ids = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: organization.id,
                            name: "Acme Corporation",
                            expectations: [.init(field: "name", value: "Acme")]
                        )
                    ),
                ]
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: organization.id,
                vaultId: fixture.vault.id,
                domainName: "acme.example"
            )
            let fetchedChanged = try fixture.repository.fetchOrganization(
                id: organization.id,
                vaultId: fixture.vault.id
            )
            let changed = try #require(fetchedChanged)
            #expect(changed.revision > organization.revision)
            let fetchedProposals = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id
            )
            let proposal = try #require(fetchedProposals.first { $0.id == ids["rename"] })

            try fixture.repository.applyCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: [proposal.id: proposal.proposal.revision]
            )
            #expect(try fixture.repository.fetchOrganization(
                id: organization.id,
                vaultId: fixture.vault.id
            )?.name == "Acme Corporation")
        }

        @Test
        // swiftlint:disable:next function_body_length
        func canonicalDeletionsStaleProposalsAndPreserveRemainingEvidence() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let unit = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Security"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "security@example.com",
                displayName: "Security Owner"
            )
            let project = ProjectRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                createdAt: .now,
                projectType: .customer
            )
            try fixture.manager.dbQueue.write { db in try project.insert(db) }
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security review",
                currentState: "Questionnaire open",
                references: [
                    .init(resourceType: .organization, resourceID: unit.id),
                    .init(resourceType: .contact, resourceID: contact.id),
                    .init(resourceType: .project, resourceID: project.id),
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "Questionnaire assigned"),
                ]
            )
            let ids = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "organization",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: unit.id,
                            name: "Risk",
                            expectations: [.init(field: "name", value: "Security")]
                        ),
                        evidence: [
                            .init(resourceType: .organization, resourceID: unit.id),
                            .init(resourceType: .meeting, resourceID: meeting.id),
                        ]
                    ),
                    .init(
                        localKey: "topic",
                        operationType: .updateTopic,
                        payload: .init(
                            targetID: topic.id,
                            currentState: "Owner confirmed",
                            expectations: [.init(field: "current_state", value: "Questionnaire open")]
                        ),
                        evidence: [
                            .init(resourceType: .topic, resourceID: topic.id),
                            .init(resourceType: .meeting, resourceID: meeting.id),
                        ]
                    ),
                ]
            )

            try fixture.repository.deleteOrganization(id: root.id, vaultId: fixture.vault.id)
            let afterOrganization = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id
            )
            let organizationProposal = try #require(afterOrganization.first { $0.id == ids["organization"] })
            #expect(organizationProposal.proposal.staleReason == "organizationDeleted")
            #expect(organizationProposal.evidence.map(\.resourceType) == ["meeting"])

            try fixture.repository.deleteConversationTopic(id: topic.id, vaultId: fixture.vault.id)
            let afterTopic = try fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id)
            let topicProposal = try #require(afterTopic.first { $0.id == ids["topic"] })
            #expect(topicProposal.proposal.staleReason == "topicDeleted")
            #expect(topicProposal.evidence.map(\.resourceType) == ["meeting"])
            try fixture.manager.dbQueue.read { db in
                let remainingMeeting = try MeetingRecord.fetchOne(db, key: meeting.id)
                let remainingContact = try ContactRecord.fetchOne(db, key: contact.id)
                let remainingProject = try ProjectRecord.fetchOne(db, key: project.id)
                #expect(remainingMeeting != nil)
                #expect(remainingContact != nil)
                #expect(remainingProject != nil)
            }
        }

        @Test
        func provisionalDeletionRejectsCalendarParticipationAndStalesReferences() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Misheard"
            )
            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: meeting.id,
                    contactId: contact.id,
                    role: .unknown,
                    responseStatus: .unknown,
                    source: "inconsistent-test-data",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            #expect(throws: CustomerIntelligenceError.provisionalContactHasParticipant) {
                try fixture.repository.deleteProvisionalContact(id: contact.id, vaultId: fixture.vault.id)
            }
            try fixture.manager.dbQueue.write { db in
                _ = try MeetingParticipantRecord
                    .filter(Column("meetingId") == meeting.id && Column("contactId") == contact.id)
                    .deleteAll(db)
            }
            let ids = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameProvisionalContact,
                        payload: .init(
                            targetID: contact.id,
                            name: "Still wrong",
                            expectations: [.init(field: "display_name", value: "Misheard")]
                        )
                    ),
                ]
            )
            try fixture.repository.deleteProvisionalContact(id: contact.id, vaultId: fixture.vault.id)
            let fetchedProposals = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id
            )
            let proposal = try #require(fetchedProposals.first { $0.id == ids["rename"] })
            #expect(proposal.proposal.staleReason == "contactDeleted")
        }

        @Test
        func proposalContractHasNoMeetingParticipantMutation() {
            #expect(!CustomerIntelligenceProposalOperationType.allCases.contains {
                $0.rawValue.contains("participant")
            })
        }

        @Test
        func organizationSearchExpandsAncestorsAndTopicFocusHighlightsRelatedNodes() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let child = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Platform"
            )
            let grandchild = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: child.id,
                nodeKind: .unit,
                name: "Security"
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security review",
                currentState: "Owner assigned",
                references: [.init(resourceType: .organization, resourceID: grandchild.id)]
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await model.load()
            model.searchText = "Security"
            await model.searchAndRevealFirstMatch()
            #expect(model.selectedNodeID == grandchild.id)
            #expect(model.expandedNodeIDs.isSuperset(of: [root.id, child.id]))
            #expect(Set(model.visibleNodes.map(\.id)).count == model.visibleNodes.count)

            await model.selectTopic(topic.id)
            #expect(model.highlightedOrganizationIDs == [grandchild.id])
            await model.toggleExpansion(child.id)
            #expect(!model.visibleNodes.contains { $0.id == grandchild.id })
        }

        @Test
        func canvasLayoutIsDeterministicAndDoesNotOverlapNodes() {
            let root = UUID.v7()
            let childA = UUID.v7()
            let childB = UUID.v7()
            let inputs = [
                OrganizationCanvasLayoutInputNode(id: root, depth: 0),
                OrganizationCanvasLayoutInputNode(id: childA, depth: 1),
                OrganizationCanvasLayoutInputNode(id: childB, depth: 1),
            ]
            let first = OrganizationCanvasLayout.calculate(nodes: inputs)
            let second = OrganizationCanvasLayout.calculate(nodes: inputs)
            #expect(first == second)
            #expect(first.positions[root]?.x != first.positions[childA]?.x)
            #expect(first.positions[childA] != first.positions[childB])
        }
    }
#endif
