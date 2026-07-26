import Foundation
@testable import Dahlia
@testable import DahliaMeetingAccess

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceAccessRegressionTests {
        @Test
        // swiftlint:disable:next function_body_length
        func cursorsAreBoundToVaultAndNormalizedFilters() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            for name in ["Acme", "Beta"] {
                _ = try repository.createOrganization(
                    vaultId: fixture.primaryVaultID,
                    parentOrganizationId: nil,
                    nodeKind: .organization,
                    name: name
                )
            }
            for email in ["alice@example.com", "bob@example.com"] {
                _ = try repository.upsertContact(
                    vaultId: fixture.primaryVaultID,
                    email: email,
                    displayName: nil
                )
            }
            for content in ["First observation", "Second observation"] {
                _ = try repository.createInsight(vaultId: fixture.primaryVaultID, content: content)
            }
            for term in ["DRI", "SLA"] {
                _ = try repository.createGlossaryTerm(
                    vaultId: fixture.primaryVaultID,
                    term: term,
                    definition: "\(term) definition"
                )
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let organizationCursor = try #require(
                store.queryOrganizations(OrganizationAccessQuery(limit: 1)).nextCursor
            )
            let contactCursor = try #require(
                store.queryContacts(ContactAccessQuery(limit: 1)).nextCursor
            )
            let insightCursor = try #require(
                store.queryInsights(InsightAccessQuery(limit: 1)).nextCursor
            )
            let glossaryCursor = try #require(
                store.queryGlossaryTerms(GlossaryAccessQuery(limit: 1)).nextCursor
            )

            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryOrganizations(OrganizationAccessQuery(
                    rootsOnly: true,
                    limit: 1,
                    cursor: organizationCursor
                ))
            }
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryContacts(ContactAccessQuery(
                    query: "alice",
                    limit: 1,
                    cursor: contactCursor
                ))
            }
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryInsights(InsightAccessQuery(
                    reviewState: .accepted,
                    limit: 1,
                    cursor: insightCursor
                ))
            }
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.queryGlossaryTerms(GlossaryAccessQuery(
                    query: "DRI",
                    limit: 1,
                    cursor: glossaryCursor
                ))
            }

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try otherStore.queryOrganizations(OrganizationAccessQuery(
                    limit: 1,
                    cursor: organizationCursor
                ))
            }
        }

        @Test
        func nestedReferencesAreBoundedAndReportTruncation() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let insight = try repository.createInsight(
                vaultId: fixture.primaryVaultID,
                content: "High-cardinality evidence"
            )
            let glossary = try repository.createGlossaryTerm(
                vaultId: fixture.primaryVaultID,
                term: "Stakeholder",
                definition: "A participant in the project"
            )

            for index in 0 ... 100 {
                let contact = try repository.upsertContact(
                    vaultId: fixture.primaryVaultID,
                    email: "contact-\(index)@example.com",
                    displayName: "Contact \(index)"
                )
                _ = try repository.addInsightReference(
                    insightId: insight.id,
                    resourceType: .contact,
                    resourceId: contact.id,
                    role: .evidence
                )
                _ = try repository.addGlossaryTermReference(
                    glossaryTermId: glossary.id,
                    resourceType: .contact,
                    resourceId: contact.id
                )
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let insightResult = try #require(store.queryInsights().insights.first)
            #expect(insightResult.references.count == 100)
            #expect(insightResult.referencesTruncated)
            #expect(insightResult.references.allSatisfy { $0.resourceName != nil })

            let glossaryResult = try #require(
                store.queryGlossaryTerms(GlossaryAccessQuery(query: "Stakeholder")).terms.first
            )
            #expect(glossaryResult.references.count == 100)
            #expect(glossaryResult.referencesTruncated)
            #expect(glossaryResult.references.allSatisfy { $0.resourceName != nil })
        }

        @Test
        func customerIntelligenceDetailsCannotCrossVaults() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let organization = try repository.createOrganization(
                vaultId: fixture.primaryVaultID,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let contact = try repository.upsertContact(
                vaultId: fixture.primaryVaultID,
                email: "owner@example.com",
                displayName: "Owner"
            )
            let glossary = try repository.createGlossaryTerm(
                vaultId: fixture.primaryVaultID,
                term: "Owner",
                definition: "The accountable contact"
            )

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(throws: MeetingAccessError.organizationNotFound) {
                try otherStore.organization(id: organization.id)
            }
            #expect(throws: MeetingAccessError.contactNotFound) {
                try otherStore.contact(id: contact.id)
            }
            #expect(throws: MeetingAccessError.glossaryTermNotFound) {
                try otherStore.glossaryTerm(id: glossary.id)
            }
        }

        @Test
        func declinedParticipantsAreNotContactInteractions() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let contact = try repository.upsertContact(
                vaultId: fixture.primaryVaultID,
                email: "declined@example.com",
                displayName: "Declined"
            )
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: fixture.firstMeetingID,
                    contactId: contact.id,
                    role: .optional,
                    responseStatus: .declined,
                    source: CalendarEventPlatform.googleCalendar,
                    createdAt: observedAt,
                    updatedAt: observedAt
                ).insert(db)
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let result = try #require(store.queryContacts(
                ContactAccessQuery(query: "declined@example.com")
            ).contacts.first)
            #expect(result.meetingCount == 0)
            #expect(result.lastInteractionAt == nil)
            #expect(try store.contact(id: contact.id).recentMeetings.isEmpty)
        }

        @Test
        func malformedOptionalJSONFallsBackWithoutPoisoningPages() throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let malformedInsight = try repository.createInsight(
                vaultId: fixture.primaryVaultID,
                content: "Malformed metadata"
            )
            let validInsight = try repository.createInsight(
                vaultId: fixture.primaryVaultID,
                content: "Valid metadata"
            )
            let malformedGlossary = try repository.createGlossaryTerm(
                vaultId: fixture.primaryVaultID,
                term: "Malformed aliases",
                definition: "Malformed aliases fixture"
            )
            let validGlossary = try repository.createGlossaryTerm(
                vaultId: fixture.primaryVaultID,
                term: "Valid aliases",
                definition: "Valid aliases fixture",
                aliases: ["Valid"]
            )
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE insights SET metadataJSON = '5' WHERE id = ?",
                    arguments: [malformedInsight.id]
                )
                try db.execute(
                    sql: "UPDATE glossary_terms SET aliasesJSON = '{}' WHERE id = ?",
                    arguments: [malformedGlossary.id]
                )
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let insights = try store.queryInsights().insights
            #expect(Set(insights.map(\.id)) == [malformedInsight.id, validInsight.id])
            #expect(insights.first(where: { $0.id == malformedInsight.id })?.metadata == .object([:]))
            let terms = try store.queryGlossaryTerms().terms
            #expect(Set(terms.map(\.id)) == [malformedGlossary.id, validGlossary.id])
            #expect(terms.first(where: { $0.id == malformedGlossary.id })?.aliases == [])
        }
    }
#endif
