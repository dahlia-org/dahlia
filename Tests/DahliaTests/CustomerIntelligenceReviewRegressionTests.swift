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
            let updated = try fixture.repository.setInsightReviewState(
                id: insight.id,
                vaultId: fixture.vault.id,
                reviewState: .accepted,
                metadataJSON: updatedJSON
            )
            #expect(updated.metadataJSON == updatedJSON)
            #expect(throws: CustomerIntelligenceError.invalidJSON) {
                try fixture.repository.setInsightReviewState(
                    id: insight.id,
                    vaultId: fixture.vault.id,
                    reviewState: .rejected,
                    metadataJSON: "[]"
                )
            }
        }
    }
#endif
