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
    }
#endif
