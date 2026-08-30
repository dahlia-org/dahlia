import Foundation
@testable import Dahlia
@testable import DahliaMeetingAccess

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceAccessRegressionTests {
        @Test
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
                    isAccepted: true,
                    limit: 1,
                    cursor: insightCursor
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
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let insightResult = try #require(store.queryInsights().insights.first)
            #expect(insightResult.references.count == 100)
            #expect(insightResult.referencesTruncated)
            #expect(insightResult.references.allSatisfy { $0.resourceName != nil })
        }

        @Test
        func organizationChartTruncationKeepsAStableBreadthFirstPrefix() async throws {
            let fixture = try Fixture()
            let repository = MeetingRepository(dbQueue: fixture.manager.dbQueue)
            let root = try repository.createOrganization(
                vaultId: fixture.primaryVaultID,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            let branchIDs = try await fixture.manager.dbQueue.write { db in
                var branchIDs: [UUID] = []
                for branchIndex in 0 ..< 5 {
                    let branch = OrganizationRecord(
                        id: .v7(),
                        vaultId: fixture.primaryVaultID,
                        parentOrganizationId: root.id,
                        nodeKind: .unit,
                        name: "Branch \(branchIndex)",
                        revision: 1,
                        createdAt: .now,
                        updatedAt: .now
                    )
                    try branch.insert(db)
                    branchIDs.append(branch.id)
                    for leafIndex in 0 ..< 100 {
                        try OrganizationRecord(
                            id: .v7(),
                            vaultId: fixture.primaryVaultID,
                            parentOrganizationId: branch.id,
                            nodeKind: .unit,
                            name: "Leaf \(branchIndex)-\(leafIndex)",
                            revision: 1,
                            createdAt: .now,
                            updatedAt: .now
                        ).insert(db)
                    }
                }
                return branchIDs
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let query = OrganizationChartAccessQuery(
                rootOrganizationID: root.id,
                maximumDepth: 2,
                childrenPerNode: 100
            )
            let (first, second) = try await Task.detached {
                try (store.queryOrganizationChart(query), store.queryOrganizationChart(query))
            }.value

            #expect(first.nodes.count == 500)
            #expect(first.nodesTruncated)
            #expect(Set(branchIDs).isSubset(of: Set(first.nodes.map(\.id))))
            #expect(first.nodes.map(\.id) == second.nodes.map(\.id))
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
            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(throws: MeetingAccessError.organizationNotFound) {
                try otherStore.organization(id: organization.id)
            }
            #expect(throws: MeetingAccessError.contactNotFound) {
                try otherStore.contact(id: contact.id)
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
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE insights SET metadataJSON = '5' WHERE id = ?",
                    arguments: [malformedInsight.id]
                )
            }

            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let insights = try store.queryInsights().insights
            #expect(Set(insights.map(\.id)) == [malformedInsight.id, validInsight.id])
            #expect(insights.first(where: { $0.id == malformedInsight.id })?.metadata == .object([:]))
        }
    }
#endif
