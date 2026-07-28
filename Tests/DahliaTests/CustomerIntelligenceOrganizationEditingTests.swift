@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceOrganizationEditingTests {
        @Test
        func organizationDetailsUpdateNameAndParentAtomically() throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let firstParent = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "First"
            )
            let secondParent = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Second"
            )
            let department = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: firstParent.id,
                nodeKind: .unit,
                name: "Old Name",
                description: "Old description"
            )

            let updated = try fixture.repository.updateOrganization(
                id: department.id,
                vaultId: fixture.vault.id,
                name: "New Name",
                parentOrganizationId: secondParent.id,
                description: "Owns the platform roadmap",
                expectedRevision: department.revision
            )

            #expect(updated.name == "New Name")
            #expect(updated.parentOrganizationId == secondParent.id)
            #expect(updated.description == "Owns the platform roadmap")
            #expect(updated.revision == department.revision + 1)
            let renamed = try fixture.repository.updateOrganization(
                id: department.id,
                vaultId: fixture.vault.id,
                name: "Newest Name",
                parentOrganizationId: secondParent.id,
                expectedRevision: updated.revision
            )
            #expect(renamed.description == "Owns the platform roadmap")
            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.updateOrganization(
                    id: department.id,
                    vaultId: fixture.vault.id,
                    name: "Stale",
                    parentOrganizationId: firstParent.id,
                    description: "Stale description",
                    expectedRevision: department.revision
                )
            }

            let matches = try fixture.repository.searchOrganizationWorkspaceNodes(
                vaultId: fixture.vault.id,
                rootOrganizationId: root.id,
                query: "platform roadmap"
            )
            #expect(matches.map(\.id) == [department.id])
        }

        @Test
        func organizationMemberPickerIncludesAssignedPeopleAndContactFilterUsesMissingEmail() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let assigned = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "assigned@example.com",
                displayName: "Assigned"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: root.id,
                contactId: assigned.id
            )
            let emailMissing = try fixture.repository.createProvisionalContact(
                vaultId: fixture.vault.id,
                displayName: "Email Missing"
            )
            let organizationModel = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await organizationModel.load()

            #expect(Set(organizationModel.contacts.map(\.id)) == [assigned.id, emailMissing.id])

            let contactsModel = CustomerIntelligenceContactsViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id,
                scope: .all
            )
            await contactsModel.load()
            contactsModel.filter = .emailMissing
            #expect(contactsModel.filteredContacts.map(\.id) == [emailMissing.id])
        }
    }
#endif
