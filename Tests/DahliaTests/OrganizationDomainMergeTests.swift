import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct OrganizationDomainMergeTests {
        @Test
        // swiftlint:disable:next function_body_length
        func mergeMovesDomainsAndCanonicalReferencesWithoutLosingTargetMetadata() throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Example"
            )
            let source = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Example Japan"
            )
            let targetObservedAt = Date.now.addingTimeInterval(-600)
            let sourceFirstObservedAt = Date.now.addingTimeInterval(-500)
            let sourceLastObservedAt = Date.now.addingTimeInterval(-100)
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "example.com",
                observedAt: targetObservedAt
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "example.co.jp",
                observedAt: sourceFirstObservedAt
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "example.co.jp",
                observedAt: sourceLastObservedAt
            )

            let sharedContact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "shared@example.co.jp",
                displayName: "Shared"
            )
            let sourceContact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "source@example.co.jp",
                displayName: "Source"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: target.id,
                contactId: sharedContact.id,
                roleLabel: "Target role"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: source.id,
                contactId: sharedContact.id,
                roleLabel: "Source role"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: source.id,
                contactId: sourceContact.id
            )
            let child = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: source.id,
                nodeKind: .unit,
                name: "Mobage"
            )
            let grandchild = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: child.id,
                nodeKind: .unit,
                name: "Platform"
            )

            let project = try fixture.repository.createCustomerIntelligenceProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Example project",
                description: "",
                projectType: .customer,
                organizationId: source.id
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .organization,
                resourceId: target.id
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .organization,
                resourceId: source.id,
                relationLabel: "Sponsor"
            )
            let topic = try fixture.repository.createConversationTopic(
                vaultId: fixture.vault.id,
                title: "Example topic",
                currentState: "Active",
                references: [
                    .init(resourceType: .organization, resourceID: source.id),
                    .init(resourceType: .organization, resourceID: target.id),
                ]
            )
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Example insight"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .organization,
                resourceId: source.id,
                role: .context
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .organization,
                resourceId: target.id,
                role: .context
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .organization,
                resourceId: source.id,
                role: .evidence
            )

            let preview = try mergePreview(
                repository: fixture.repository,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "example.co.jp"
            )
            #expect(preview.impact == OrganizationMergeImpact(
                domains: 1,
                memberships: 2,
                descendantOrganizations: 2,
                projects: 1,
                topics: 1,
                insights: 1
            ))

            let merged = try fixture.repository.mergeOrganization(
                sourceOrganizationId: source.id,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                expectedSourceDomainName: preview.domainName,
                expectedSourceRevision: preview.source.revision,
                expectedTargetRevision: preview.target.revision,
                expectedImpact: preview.impact
            )

            #expect(merged.id == target.id)
            #expect(merged.name == "Example")
            try fixture.manager.dbQueue.write { db in
                #expect(try OrganizationRecord.fetchOne(db, key: source.id) == nil)
                #expect(try OrganizationRecord.fetchOne(db, key: child.id)?.parentOrganizationId == target.id)
                #expect(try OrganizationRecord.fetchOne(db, key: grandchild.id)?.parentOrganizationId == child.id)

                let domains = try OrganizationDomainRecord
                    .filter(Column("organizationId") == target.id)
                    .order(Column("isPrimary").desc, Column("domainName").asc)
                    .fetchAll(db)
                #expect(domains.map(\.domainName) == ["example.com", "example.co.jp"])
                #expect(domains.first?.isPrimary == true)
                let movedDomain = try #require(domains.first { $0.domainName == "example.co.jp" })
                #expect(abs(movedDomain.firstObservedAt.timeIntervalSince(sourceFirstObservedAt)) < 0.001)
                #expect(abs(movedDomain.lastObservedAt.timeIntervalSince(sourceLastObservedAt)) < 0.001)

                let memberships = try OrganizationMembershipRecord
                    .filter(Column("organizationId") == target.id)
                    .fetchAll(db)
                #expect(Set(memberships.map(\.contactId)) == [sharedContact.id, sourceContact.id])
                #expect(memberships.first { $0.contactId == sharedContact.id }?.roleLabel == "Target role")

                let projectReferences = try ProjectResourceReferenceRecord
                    .filter(Column("projectId") == project.id && Column("resourceType") == CustomerResourceType.organization)
                    .fetchAll(db)
                #expect(projectReferences.count == 2)
                #expect(projectReferences.allSatisfy { $0.resourceId == target.id })
                #expect(try ConversationTopicReferenceRecord
                    .filter(
                        Column("topicId") == topic.id
                            && Column("resourceType") == ConversationTopicResourceType.organization
                    )
                    .fetchAll(db)
                    .map(\.resourceId) == [target.id])
                let insightReferences = try InsightReferenceRecord
                    .filter(
                        Column("insightId") == insight.id
                            && Column("resourceType") == CustomerResourceType.organization
                    )
                    .fetchAll(db)
                #expect(insightReferences.count == 2)
                #expect(insightReferences.allSatisfy { $0.resourceId == target.id })

                let resolved = try CustomerIntelligencePersistence.organizations(
                    forDomain: "example.co.jp",
                    vaultId: fixture.vault.id,
                    observedAt: .now,
                    automaticallyCreate: true,
                    in: db
                )
                #expect(resolved.map(\.id) == [target.id])
            }
        }

        @Test
        func stalePreviewRollsBackWithoutMovingTheDomain() throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Target"
            )
            let source = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Source"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "source.example"
            )
            let preview = try mergePreview(
                repository: fixture.repository,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "source.example"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "target.example"
            )

            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.mergeOrganization(
                    sourceOrganizationId: source.id,
                    targetOrganizationId: target.id,
                    vaultId: fixture.vault.id,
                    expectedSourceDomainName: preview.domainName,
                    expectedSourceRevision: preview.source.revision,
                    expectedTargetRevision: preview.target.revision,
                    expectedImpact: preview.impact
                )
            }

            #expect(try fixture.repository
                .fetchOrganizationDomains(organizationId: source.id, vaultId: fixture.vault.id)
                .map(\.domainName) == ["source.example"])
            #expect(try fixture.repository.fetchOrganization(id: source.id, vaultId: fixture.vault.id) != nil)
        }

        @Test
        func mergeRejectsAnOrganizationThatNoLongerOwnsTheRequestedDomain() throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Target"
            )
            let formerOwner = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Former owner"
            )
            let currentOwner = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Current owner"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: formerOwner.id,
                vaultId: fixture.vault.id,
                domainName: "moved.example"
            )
            try fixture.repository.removeOrganizationDomain(
                organizationId: formerOwner.id,
                vaultId: fixture.vault.id,
                domainName: "moved.example"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: currentOwner.id,
                vaultId: fixture.vault.id,
                domainName: "moved.example"
            )

            let currentFormerOwner = try #require(
                try fixture.repository.fetchOrganization(id: formerOwner.id, vaultId: fixture.vault.id)
            )
            let currentTarget = try #require(
                try fixture.repository.fetchOrganization(id: target.id, vaultId: fixture.vault.id)
            )
            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.mergeOrganization(
                    sourceOrganizationId: formerOwner.id,
                    targetOrganizationId: target.id,
                    vaultId: fixture.vault.id,
                    expectedSourceDomainName: "moved.example",
                    expectedSourceRevision: currentFormerOwner.revision,
                    expectedTargetRevision: currentTarget.revision,
                    expectedImpact: OrganizationMergeImpact(
                        domains: 0,
                        memberships: 0,
                        descendantOrganizations: 0,
                        projects: 0,
                        topics: 0,
                        insights: 0
                    )
                )
            }

            let plan = try fixture.repository.organizationDomainAssignmentPlan(
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "moved.example",
                expectedTargetRevision: currentTarget.revision
            )
            guard case let .merge(preview) = plan else {
                Issue.record("Expected a merge plan for the domain's current owner")
                return
            }
            #expect(preview.source.id == currentOwner.id)
            #expect(try fixture.repository.fetchOrganization(
                id: formerOwner.id,
                vaultId: fixture.vault.id
            ) != nil)
        }

        @Test
        func mergePreservesTheSourcePrimaryDomainWhenTheTargetHasNone() throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Target"
            )
            let source = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Source"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "older.example",
                observedAt: Date.now.addingTimeInterval(-100)
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "primary.example"
            )
            try fixture.repository.setPrimaryOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "primary.example"
            )
            let preview = try mergePreview(
                repository: fixture.repository,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "older.example"
            )

            _ = try fixture.repository.mergeOrganization(
                sourceOrganizationId: source.id,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                expectedSourceDomainName: preview.domainName,
                expectedSourceRevision: preview.source.revision,
                expectedTargetRevision: preview.target.revision,
                expectedImpact: preview.impact
            )

            let domains = try fixture.repository.fetchOrganizationDomains(
                organizationId: target.id,
                vaultId: fixture.vault.id
            )
            #expect(domains.first(where: \.isPrimary)?.domainName == "primary.example")
        }

        @Test
        func mergeCoalescesDomainAlreadySharedWithTarget() throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Target"
            )
            let source = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Source"
            )
            let older = Date.now.addingTimeInterval(-1000)
            let newer = Date.now
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "shared.example",
                observedAt: newer
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "shared.example",
                observedAt: older
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "source.example"
            )
            let preview = try mergePreview(
                repository: fixture.repository,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "source.example"
            )

            _ = try fixture.repository.mergeOrganization(
                sourceOrganizationId: source.id,
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                expectedSourceDomainName: preview.domainName,
                expectedSourceRevision: preview.source.revision,
                expectedTargetRevision: preview.target.revision,
                expectedImpact: preview.impact
            )

            let domains = try fixture.repository.fetchOrganizationDomains(
                organizationId: target.id,
                vaultId: fixture.vault.id
            )
            #expect(domains.map(\.domainName).sorted() == ["shared.example", "source.example"])
            let shared = try #require(domains.first { $0.domainName == "shared.example" })
            #expect(abs(shared.firstObservedAt.timeIntervalSince(older)) < 0.001)
            #expect(abs(shared.lastObservedAt.timeIntervalSince(newer)) < 0.001)
            #expect(domains.count(where: \.isPrimary) == 1)
        }

        @Test
        func domainSharedByMultipleOwnersIsAddedWithoutOfferingMerge() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organizations = try ["First", "Second", "Target"].map { name in
                try fixture.repository.createOrganization(
                    vaultId: fixture.vault.id,
                    parentOrganizationId: nil,
                    nodeKind: .organization,
                    name: name
                )
            }
            for organization in organizations.prefix(2) {
                _ = try fixture.repository.addOrganizationDomain(
                    organizationId: organization.id,
                    vaultId: fixture.vault.id,
                    domainName: "shared.example"
                )
            }
            let target = organizations[2]
            let currentTarget = try #require(
                try fixture.repository.fetchOrganization(id: target.id, vaultId: fixture.vault.id)
            )
            let plan = try fixture.repository.organizationDomainAssignmentPlan(
                targetOrganizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "shared.example",
                expectedTargetRevision: currentTarget.revision
            )
            #expect(plan == .shared)
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: target.id,
                vaultId: fixture.vault.id,
                domainName: "shared.example",
                expectedOrganizationRevision: currentTarget.revision
            )
            let assignments = try fixture.manager.dbQueue.read { db in
                try OrganizationDomainRecord
                    .filter(Column("domainName") == "shared.example")
                    .fetchCount(db)
            }
            #expect(assignments == 3)
        }

        @Test
        func viewModelAddsANewDomainAndPreparesAnExistingOwnerForMerge() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "A Target"
            )
            let source = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "B Source"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: source.id,
                vaultId: fixture.vault.id,
                domainName: "source.example"
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            await model.load(selectingRootID: target.id)

            #expect(await model.addDomain("TARGET.EXAMPLE.", to: target))
            #expect(model.selectedDetail?.domains.map(\.domainName) == ["target.example"])

            let refreshedTarget = try #require(model.loadedNodes[target.id]?.organization)
            #expect(await model.addDomain("source.example", to: refreshedTarget))
            let pending = try #require(model.pendingMerge)
            #expect(pending.preview.source.id == source.id)
            #expect(pending.preview.target.id == target.id)
            #expect(try fixture.repository.fetchOrganization(id: source.id, vaultId: fixture.vault.id) != nil)

            await model.confirmMerge(pending)

            #expect(model.pendingMerge == nil)
            #expect(model.selectedDetail?.domains.map(\.domainName) == ["target.example", "source.example"])
            #expect(try fixture.repository.fetchOrganization(id: source.id, vaultId: fixture.vault.id) == nil)
        }

        @Test
        func staleDomainSheetCannotAssignToAReplacementOrganization() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let target = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Target"
            )
            _ = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Replacement"
            )
            let model = OrganizationWorkspaceViewModel(
                dbQueue: fixture.manager.dbQueue,
                vaultID: fixture.vault.id
            )
            await model.load(selectingRootID: target.id)
            let capturedTarget = try #require(model.loadedNodes[target.id]?.organization)
            try fixture.repository.deleteOrganization(id: target.id, vaultId: fixture.vault.id)
            await model.load()

            #expect(await !(model.addDomain("stale.example", to: capturedTarget)))
            #expect(model.errorMessage != nil)
            let staleDomain = try await fixture.manager.dbQueue.read { db in
                try OrganizationDomainRecord
                    .filter(
                        Column("vaultId") == fixture.vault.id
                            && Column("domainName") == "stale.example"
                    )
                    .fetchOne(db)
            }
            #expect(staleDomain == nil)
        }

        @Test
        func mergeImpactUsesSingularLabels() {
            let title = L10n.organizationDomainAlreadyUsed(by: "Source")
            let message = L10n.organizationMergeImpact(
                domainName: "source.example",
                targetName: "Target",
                impact: OrganizationMergeImpact(
                    domains: 1,
                    memberships: 1,
                    descendantOrganizations: 1,
                    projects: 1,
                    topics: 1,
                    insights: 1
                )
            )

            #expect(title.contains("Source"))
            #expect(message.contains("Target"))
            #expect(!message.contains("1 domains"))
            #expect(!message.contains("1 memberships"))
            #expect(!message.contains("1 departments"))
        }

        private func mergePreview(
            repository: MeetingRepository,
            targetOrganizationId: UUID,
            vaultId: UUID,
            domainName: String
        ) throws -> OrganizationMergePreview {
            let target = try #require(
                try repository.fetchOrganization(id: targetOrganizationId, vaultId: vaultId)
            )
            let plan = try repository.organizationDomainAssignmentPlan(
                targetOrganizationId: targetOrganizationId,
                vaultId: vaultId,
                domainName: domainName,
                expectedTargetRevision: target.revision
            )
            guard case let .merge(preview) = plan else {
                throw CustomerIntelligenceError.invalidOrganizationMerge
            }
            return preview
        }
    }
#endif
