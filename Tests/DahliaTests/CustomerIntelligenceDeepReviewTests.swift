import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceDeepReviewTests {
        @Test
        func appAppliesDependentCreationsInOrderAndRejectsSameFieldConflicts() throws {
            let fixture = try CustomerIntelligenceFixture()
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "organization",
                        operationType: .createOrganization,
                        payload: .init(nodeKind: "organization", name: "Acme")
                    ),
                    .init(
                        localKey: "contact",
                        operationType: .createProvisionalContact,
                        payload: .init(name: "Owner")
                    ),
                    .init(
                        localKey: "membership",
                        operationType: .setMembership,
                        payload: .init(
                            organizationLocalKey: "organization",
                            contactLocalKey: "contact",
                            expectations: [.init(field: "role_label", value: nil)]
                        ),
                        dependsOn: ["organization", "contact"]
                    ),
                ]
            )
            let proposals = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                status: .proposed
            )
            try fixture.repository.applyCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0.proposal.revision) })
            )
            let organization = try #require(
                fixture.repository.fetchOrganizations(vaultId: fixture.vault.id).first
            )
            #expect(try fixture.manager.dbQueue.read {
                try OrganizationMembershipRecord.fetchCount($0)
            } == 1)

            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "first",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: organization.id,
                            name: "First",
                            expectations: [.init(field: "name", value: "Acme")]
                        )
                    ),
                    .init(
                        localKey: "second",
                        operationType: .renameOrganization,
                        payload: .init(
                            targetID: organization.id,
                            name: "Second",
                            expectations: [.init(field: "name", value: "Acme")]
                        )
                    ),
                ]
            )
            let renames = try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                status: .proposed
            )
            #expect(throws: CustomerIntelligenceError.proposalConflict) {
                try fixture.repository.applyCustomerIntelligenceProposals(
                    vaultId: fixture.vault.id,
                    revisions: Dictionary(uniqueKeysWithValues: renames.map {
                        ($0.id, $0.proposal.revision)
                    })
                )
            }
            #expect(try fixture.repository.fetchOrganization(
                id: organization.id,
                vaultId: fixture.vault.id
            )?.name == "Acme")
        }

        @Test
        // swiftlint:disable:next function_body_length
        func contactResolutionPreservesEverySourceOnlyReference() throws {
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
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: organization.id,
                contactId: provisional.id
            )
            let project = ProjectRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Customer",
                createdAt: .now,
                projectType: .customer
            )
            try fixture.manager.dbQueue.write { try project.insert($0) }
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .contact,
                resourceId: provisional.id,
                relationLabel: "Sponsor"
            )
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Decision maker"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: provisional.id,
                role: .evidence
            )
            let glossary = try fixture.repository.createGlossaryTerm(
                vaultId: fixture.vault.id,
                term: "DRI",
                definition: "Owner"
            )
            _ = try fixture.repository.addGlossaryTermReference(
                glossaryTermId: glossary.id,
                resourceType: .contact,
                resourceId: provisional.id
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security",
                currentState: "Open",
                references: [.init(resourceType: .contact, resourceID: provisional.id)]
            )
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
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
            let proposal = try #require(
                fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id).first
            )
            try fixture.repository.applyCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: [proposal.id: proposal.proposal.revision]
            )

            try fixture.manager.dbQueue.read { db in
                let membershipCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM organization_memberships WHERE contactId = ?",
                    arguments: [provisional.id]
                )
                #expect(membershipCount == 0)
                for table in [
                    "project_resource_references",
                    "insight_references",
                    "glossary_term_references",
                    "conversation_topic_references",
                    "customer_intelligence_proposal_evidence",
                ] {
                    let sourceCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM \(table) WHERE resourceId = ?",
                        arguments: [provisional.id]
                    )
                    #expect(sourceCount == 0)
                }
                let projectContactID = try UUID.fetchOne(
                    db,
                    sql: """
                    SELECT resourceId FROM project_resource_references
                    WHERE projectId = ? AND relationLabel = 'Sponsor'
                    """,
                    arguments: [project.id]
                )
                #expect(projectContactID == identified.id)
                let topicContactID = try UUID.fetchOne(
                    db,
                    sql: "SELECT resourceId FROM conversation_topic_references WHERE topicId = ?",
                    arguments: [topic.id]
                )
                #expect(topicContactID == identified.id)
            }
        }

        @Test
        func staleProposalCanBeRejectedAndClearsReason() throws {
            let fixture = try CustomerIntelligenceFixture()
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Misheard"
            )
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "rename",
                        operationType: .renameProvisionalContact,
                        payload: .init(
                            targetID: contact.id,
                            name: "Corrected",
                            expectations: [.init(field: "display_name", value: "Misheard")]
                        )
                    ),
                ]
            )
            try fixture.repository.deleteProvisionalContact(id: contact.id, vaultId: fixture.vault.id)
            let stale = try #require(
                fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id).first
            )
            try fixture.repository.rejectCustomerIntelligenceProposals(
                vaultId: fixture.vault.id,
                revisions: [stale.id: stale.proposal.revision]
            )
            let rejected = try #require(
                fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id).first
            )
            #expect(rejected.proposal.status == .rejected)
            #expect(rejected.proposal.staleReason == nil)
        }

        @Test
        func proposalBoundsAndTopicReferenceShapeAreValidatedBeforeStorage() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            #expect(throws: CustomerIntelligenceError.invalidProposal) {
                try fixture.repository.proposeCustomerIntelligenceChanges(
                    vaultId: fixture.vault.id,
                    inputs: [
                        .init(
                            localKey: String(repeating: "a", count: 129),
                            operationType: .createTopic,
                            payload: .init(title: "Topic", currentState: "Open")
                        ),
                    ]
                )
            }
            #expect(throws: CustomerIntelligenceError.invalidProposal) {
                try fixture.repository.proposeCustomerIntelligenceChanges(
                    vaultId: fixture.vault.id,
                    inputs: [
                        .init(
                            localKey: "topic",
                            operationType: .createTopic,
                            payload: .init(
                                title: "Topic",
                                currentState: "Open",
                                references: [.init(resourceType: .meeting, resourceID: meeting.id)]
                            )
                        ),
                    ]
                )
            }
            #expect(try fixture.repository.fetchCustomerIntelligenceProposals(
                vaultId: fixture.vault.id
            ).isEmpty)
        }

        @Test
        func topicExpectationCannotCollideThroughMeetingNoteDelimiters() throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let injected = "foo|organization:"
                + organization.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ":"
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security",
                currentState: "Open",
                references: [.init(resourceType: .meeting, resourceID: meeting.id, note: injected)]
            )
            let expectation = try CustomerIntelligenceTopicReferenceExpectation.encode([
                .init(resourceType: "meeting", resourceID: meeting.id, note: injected),
            ])
            _ = try fixture.repository.proposeCustomerIntelligenceChanges(
                vaultId: fixture.vault.id,
                inputs: [
                    .init(
                        localKey: "references",
                        operationType: .setTopicReferences,
                        payload: .init(
                            targetID: topic.id,
                            references: [.init(
                                resourceType: .meeting,
                                resourceID: meeting.id,
                                note: "Replacement"
                            )],
                            expectations: [.init(field: "references", value: expectation)]
                        )
                    ),
                ]
            )
            try fixture.repository.replaceConversationTopicReferences(
                topicId: topic.id,
                vaultId: fixture.vault.id,
                expectedRevision: topic.revision,
                references: [
                    .init(resourceType: .meeting, resourceID: meeting.id, note: "foo"),
                    .init(resourceType: .organization, resourceID: organization.id),
                ]
            )
            let proposal = try #require(
                fixture.repository.fetchCustomerIntelligenceProposals(vaultId: fixture.vault.id).first
            )
            #expect(throws: CustomerIntelligenceError.proposalConflict) {
                try fixture.repository.applyCustomerIntelligenceProposals(
                    vaultId: fixture.vault.id,
                    revisions: [proposal.id: proposal.proposal.revision]
                )
            }
        }

        @Test
        func deletionConfirmationRejectsChangedImpact() throws {
            let fixture = try CustomerIntelligenceFixture()
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Misheard"
            )
            let impact = try fixture.repository.provisionalContactDeletionImpact(
                id: contact.id,
                vaultId: fixture.vault.id
            )
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: organization.id,
                contactId: contact.id
            )
            #expect(throws: CustomerIntelligenceError.proposalConflict) {
                try fixture.repository.deleteProvisionalContact(
                    id: contact.id,
                    vaultId: fixture.vault.id,
                    expectedRevision: contact.revision,
                    expectedImpact: impact
                )
            }
            #expect(try fixture.repository.fetchContact(id: contact.id, vaultId: fixture.vault.id) != nil)
        }

        @Test
        func referenceCleanupUpdatesTopicTimestampThroughLatestMigration() throws {
            let fixture = try CustomerIntelligenceFixture()
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Owner"
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security",
                currentState: "Open",
                references: [.init(resourceType: .contact, resourceID: contact.id)]
            )
            let oldDate = Date(timeIntervalSince1970: 1_000_000_000)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE conversation_topics SET updatedAt = ? WHERE id = ?",
                    arguments: [oldDate, topic.id]
                )
                _ = try ContactRecord.deleteOne(db, key: contact.id)
            }
            let updated = try #require(try fixture.repository.fetchConversationTopic(
                id: topic.id,
                vaultId: fixture.vault.id
            ))
            #expect(updated.0.topic.updatedAt > oldDate)
        }

        @Test
        func vaultSwitchClearsProjectionAndTopicHighlightsContactMembership() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Owner",
                organizationId: organization.id,
                expectedOrganizationRevision: organization.revision
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Security",
                currentState: "Open",
                references: [.init(resourceType: .contact, resourceID: contact.id)]
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            await model.load()
            await model.selectTopic(topic.id)
            #expect(model.highlightedOrganizationIDs == [organization.id])

            await model.changeVault(to: fixture.otherVault.id)
            #expect(model.roots.isEmpty)
            #expect(model.loadedNodes.isEmpty)
            #expect(model.proposals.isEmpty)
            #expect(model.allTopics.isEmpty)
            #expect(model.selectedTopicID == nil)
        }

        @Test
        func layoutPreservesInputOrderWithinDepth() {
            let firstID = UUID.v7()
            let secondID = UUID.v7()
            let result = OrganizationCanvasLayout.calculate(nodes: [
                .init(id: secondID, depth: 1),
                .init(id: firstID, depth: 1),
            ])
            #expect((result.positions[secondID]?.y ?? 1) < (result.positions[firstID]?.y ?? 0))
        }
    }
#endif
