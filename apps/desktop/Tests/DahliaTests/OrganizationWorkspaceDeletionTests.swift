@testable import Dahlia

#if canImport(Testing)
    import Dispatch
    import Testing

    @MainActor
    struct OrganizationWorkspaceDeletionTests {
        @Test
        func contactAndOrganizationDeletionUseTheirOwningViewModels() async throws {
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
            let contactModel = CustomerIntelligenceContactsViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id,
                scope: .all
            )
            let organizationModel = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )

            await contactModel.load(selectedID: contact.id)
            await contactModel.prepareDeletion(contact)
            let contactConfirmation = try #require(contactModel.pendingDeletion)
            #expect(contactConfirmation.id == contact.id)
            _ = await contactModel.confirmDeletion(contactConfirmation)
            let deletedContact = try await fixture.manager.dbQueue.read {
                try ContactRecord.fetchOne($0, key: contact.id)
            }
            #expect(deletedContact == nil)

            await organizationModel.load()
            await organizationModel.prepareOrganizationDeletion()
            let organizationConfirmation = try #require(organizationModel.pendingDeletion)
            #expect(organizationConfirmation.id == organization.id)
            await organizationModel.confirmDeletion(organizationConfirmation)
            let deletedOrganization = try await fixture.manager.dbQueue.read {
                try OrganizationRecord.fetchOne($0, key: organization.id)
            }
            #expect(deletedOrganization == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func workspaceChangeDuringDeletionPreparationStillPresentsConfirmation() async throws {
            let (fixture, organization, model) = try await makeDeletionFixture()

            let databaseLockStarted = AsyncStream.makeStream(of: Void.self)
            let releaseDatabaseLock = DispatchSemaphore(value: 0)
            let dbQueue = fixture.manager.dbQueue
            let databaseLockTask = Task.detached {
                try dbQueue.write { db in
                    guard var changedOrganization = try OrganizationRecord.fetchOne(db, key: organization.id) else {
                        throw CustomerIntelligenceError.organizationNotFound
                    }
                    changedOrganization.name = "Acme Japan Updated"
                    changedOrganization.revision += 1
                    changedOrganization.updatedAt = .now
                    try changedOrganization.update(db)
                    databaseLockStarted.continuation.yield()
                    databaseLockStarted.continuation.finish()
                    releaseDatabaseLock.wait()
                }
            }
            var databaseLockEvents = databaseLockStarted.stream.makeAsyncIterator()
            _ = await databaseLockEvents.next()
            var databaseLockReleased = false
            defer {
                if !databaseLockReleased {
                    releaseDatabaseLock.signal()
                }
            }

            let preparation = Task { await model.prepareOrganizationDeletion() }
            // Spinning on Task.yield() here starves every other MainActor test while the
            // database lock below is held.
            let didStartPreparing = await pollUntil { model.isPreparingDeletion }
            #expect(didStartPreparing)
            let reloadWasDeferred = await withTaskCancellationHandler {
                await model.handleWorkspaceChange()
            } onCancel: {
                releaseDatabaseLock.signal()
            }
            #expect(reloadWasDeferred)
            releaseDatabaseLock.signal()
            databaseLockReleased = true

            await preparation.value
            try await databaseLockTask.value
            let confirmation = try #require(model.pendingDeletion)
            #expect(confirmation.id == organization.id)
            try await confirmAndVerifyDeletion(
                confirmation,
                originalOrganization: organization,
                model: model,
                fixture: fixture
            )
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

        private func makeDeletionFixture() async throws
            -> (CustomerIntelligenceFixture, OrganizationRecord, OrganizationWorkspaceViewModel) {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .organization,
                name: "Acme Japan"
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            await model.load()
            await model.revealOrganization(organization.id)
            return (fixture, organization, model)
        }

        private func confirmAndVerifyDeletion(
            _ confirmation: OrganizationWorkspaceViewModel.PendingOrganizationDeletion,
            originalOrganization: OrganizationRecord,
            model: OrganizationWorkspaceViewModel,
            fixture: CustomerIntelligenceFixture
        ) async throws {
            #expect(confirmation.organization.revision == originalOrganization.revision + 1)
            await model.confirmDeletion(confirmation)
            let deletedOrganization = try await fixture.manager.dbQueue.read {
                try OrganizationRecord.fetchOne($0, key: originalOrganization.id)
            }
            #expect(deletedOrganization == nil)
        }
    }
#endif
