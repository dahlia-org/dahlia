@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct OrganizationWorkspaceDeletionTests {
        @Test
        func contactAndOrganizationDeletionUseTheSharedConfirmationAlert() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let contact = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Misheard",
                organizationId: organization.id
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await model.load()
            await model.prepareContactDeletion(contact)
            let contactConfirmation = try #require(model.pendingDeletion)
            guard case let .contact(pendingContact) = contactConfirmation else {
                Issue.record("Expected a contact deletion confirmation")
                return
            }
            #expect(pendingContact.id == contact.id)
            model.pendingDeletion = nil
            await model.confirmDeletion(contactConfirmation)
            let deletedContact = try await fixture.manager.dbQueue.read {
                try ContactRecord.fetchOne($0, key: contact.id)
            }
            #expect(deletedContact == nil)

            await model.prepareOrganizationDeletion()
            let organizationConfirmation = try #require(model.pendingDeletion)
            guard case let .organization(pendingOrganization) = organizationConfirmation else {
                Issue.record("Expected an organization deletion confirmation")
                return
            }
            #expect(pendingOrganization.id == organization.id)
            model.pendingDeletion = nil
            await model.confirmDeletion(organizationConfirmation)
            let deletedOrganization = try await fixture.manager.dbQueue.read {
                try OrganizationRecord.fetchOne($0, key: organization.id)
            }
            #expect(deletedOrganization == nil)
        }

        @Test
        func organizationHierarchyOnlyOffersTopicsInTheSelectedCustomerScope() async throws {
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
            let firstTopic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "First topic",
                currentState: "Active",
                references: [.init(resourceType: .organization, resourceID: first.id)]
            )
            let secondTopic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Second topic",
                currentState: "Active",
                references: [.init(resourceType: .organization, resourceID: second.id)]
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await model.load()
            await model.selectRoot(first.id)

            #expect(model.allTopics.map(\.id) == [firstTopic.id])
            await model.selectTopic(secondTopic.id)
            #expect(model.selectedTopicID == nil)
            #expect(model.selectedTopicEvidence.isEmpty)
        }
    }
#endif
