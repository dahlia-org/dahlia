import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceReviewRegressionTests {
        @Test
        func deletingOrganizationRemovesItsEntireSubtree() throws {
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
                name: "Engineering"
            )
            _ = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: child.id,
                nodeKind: .unit,
                name: "Platform"
            )

            try fixture.repository.deleteOrganization(id: root.id, vaultId: fixture.vault.id)

            #expect(try fixture.repository.fetchOrganizations(vaultId: fixture.vault.id).isEmpty)
        }

        @Test
        func organizationDeletionImpactIncludesNewInsightReferences() throws {
            let fixture = try CustomerIntelligenceFixture()
            let organization = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let firstInsight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "First"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: firstInsight.id,
                resourceType: .organization,
                resourceId: organization.id,
                role: .context
            )
            let initialImpact = try fixture.repository.organizationDeletionImpact(
                id: organization.id,
                vaultId: fixture.vault.id
            )
            #expect(initialImpact.insights == 1)

            let secondInsight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Second"
            )
            _ = try fixture.repository.addInsightReference(
                insightId: secondInsight.id,
                resourceType: .organization,
                resourceId: organization.id,
                role: .context
            )
            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.deleteOrganization(
                    id: organization.id,
                    vaultId: fixture.vault.id,
                    expectedImpact: initialImpact
                )
            }
        }

        @Test
        func insightMetadataValidationPreservesNumericLexemes() throws {
            let fixture = try CustomerIntelligenceFixture()
            let original = #"{"confidence":0.7,"weight":1.10}"#
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Numeric metadata",
                metadataJSON: original
            )
            #expect(insight.metadataJSON == original)

            let updatedJSON = #"{"confidence":0.70,"weight":1.100}"#
            let updated = try fixture.repository.setInsightAccepted(
                id: insight.id,
                vaultId: fixture.vault.id,
                expectedRevision: insight.revision,
                isAccepted: true,
                metadataJSON: updatedJSON
            )
            #expect(updated.metadataJSON == updatedJSON)
            #expect(throws: CustomerIntelligenceError.invalidJSON) {
                try fixture.repository.setInsightAccepted(
                    id: insight.id,
                    vaultId: fixture.vault.id,
                    expectedRevision: updated.revision,
                    isAccepted: false,
                    metadataJSON: "[]"
                )
            }
            #expect(throws: CustomerIntelligenceError.revisionConflict) {
                try fixture.repository.setInsightAccepted(
                    id: insight.id,
                    vaultId: fixture.vault.id,
                    expectedRevision: insight.revision,
                    isAccepted: false
                )
            }
        }

        @Test
        func scopedOverviewCountsAreIndependentOfProjectionLimits() throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            try seedHighCardinalityCustomerIntelligence(
                count: 501,
                organizationID: root.id,
                fixture: fixture
            )
            let scope = CustomerIntelligenceScope.organization(root.id)

            let counts = try fixture.repository.fetchCustomerIntelligenceCounts(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let overview = try fixture.repository.fetchCustomerIntelligenceOverview(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let projects = try fixture.repository.fetchCustomerIntelligenceProjects(
                vaultId: fixture.vault.id,
                scope: scope
            )
            let card = try #require(
                fixture.repository.fetchCustomerIntelligenceCustomerCards(vaultId: fixture.vault.id).first
            )

            #expect(counts.contacts == 501)
            #expect(counts.projects == 501)
            #expect(counts.topics == 501)
            #expect(counts.unacceptedInsights == 501)
            #expect(overview.counts == counts)
            #expect(projects.count == 500)
            #expect(card.contactCount == 501)
            #expect(card.projectCount == 501)
            #expect(card.topicCount == 501)
        }

        private func seedHighCardinalityCustomerIntelligence(
            count: Int,
            organizationID: UUID,
            fixture: CustomerIntelligenceFixture
        ) throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try fixture.manager.dbQueue.write { db in
                for index in 0 ..< count {
                    let contact = ContactRecord(
                        id: .v7(),
                        vaultId: fixture.vault.id,
                        email: nil,
                        displayName: "Contact \(index)",
                        revision: 1,
                        createdAt: now,
                        updatedAt: now
                    )
                    try contact.insert(db)
                    try OrganizationMembershipRecord(
                        organizationId: organizationID,
                        contactId: contact.id,
                        roleLabel: nil,
                        createdAt: now
                    ).insert(db)

                    let project = ProjectRecord(
                        id: .v7(),
                        vaultId: fixture.vault.id,
                        parentProjectId: nil,
                        name: "Project \(index)",
                        createdAt: now,
                        projectType: .customer
                    )
                    try project.insert(db)
                    try ProjectResourceReferenceRecord(
                        id: .v7(),
                        projectId: project.id,
                        resourceType: .organization,
                        resourceId: organizationID,
                        relationLabel: "context",
                        createdAt: now,
                        updatedAt: now
                    ).insert(db)

                    let topic = ConversationTopicRecord(
                        id: .v7(),
                        vaultId: fixture.vault.id,
                        title: "Topic \(index)",
                        currentState: "Active",
                        revision: 1,
                        createdAt: now,
                        updatedAt: now
                    )
                    try topic.insert(db)
                    try ConversationTopicReferenceRecord(
                        topicId: topic.id,
                        resourceType: .organization,
                        resourceId: organizationID,
                        note: nil,
                        createdAt: now,
                        updatedAt: now
                    ).insert(db)

                    let insight = InsightRecord(
                        id: .v7(),
                        vaultId: fixture.vault.id,
                        content: "Insight \(index)",
                        isAccepted: false,
                        metadataJSON: "{}",
                        revision: 1,
                        createdAt: now,
                        updatedAt: now
                    )
                    try insight.insert(db)
                    try InsightReferenceRecord(
                        insightId: insight.id,
                        resourceType: .organization,
                        resourceId: organizationID,
                        referenceRole: .context,
                        createdAt: now
                    ).insert(db)
                }
            }
        }
    }
#endif
