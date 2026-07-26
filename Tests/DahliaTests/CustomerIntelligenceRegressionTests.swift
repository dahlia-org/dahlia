import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceRegressionTests {
        @Test
        // swiftlint:disable:next function_body_length
        func nestedOrganizationsAllowVaultDeletionAndEntityVaultsAreImmutable() throws {
            let fixture = try CustomerIntelligenceFixture()
            let root = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: nil,
                nodeKind: .organization,
                name: "Acme"
            )
            _ = try fixture.repository.createOrganization(
                vaultId: fixture.vault.id,
                parentOrganizationId: root.id,
                nodeKind: .unit,
                name: "Platform"
            )
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@acme.example",
                displayName: "Owner"
            )
            _ = try fixture.repository.addOrganizationDomain(
                organizationId: root.id,
                vaultId: fixture.vault.id,
                domainName: "acme.example"
            )
            _ = try fixture.repository.addOrganizationMembership(
                organizationId: root.id,
                contactId: contact.id
            )
            let meeting = try fixture.insertMeeting()
            try fixture.manager.dbQueue.write { db in
                try MeetingParticipantRecord(
                    meetingId: meeting.id,
                    contactId: contact.id,
                    role: .required,
                    responseStatus: .accepted,
                    source: "test",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let project = try fixture.repository.createProject(
                vaultId: fixture.vault.id,
                parentProjectId: nil,
                name: "Acme Project",
                description: "",
                projectType: .customer
            )
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Owner is the sponsor"
            )
            let glossary = try fixture.repository.createGlossaryTerm(
                vaultId: fixture.vault.id,
                term: "DRI",
                definition: "Directly responsible individual"
            )
            _ = try fixture.repository.addProjectResourceReference(
                projectId: project.id,
                resourceType: .organization,
                resourceId: root.id
            )
            _ = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: contact.id,
                role: .evidence
            )
            _ = try fixture.repository.addGlossaryTermReference(
                glossaryTermId: glossary.id,
                resourceType: .meeting,
                resourceId: meeting.id
            )

            for (table, id) in [
                (ContactRecord.databaseTableName, contact.id),
                (MeetingRecord.databaseTableName, meeting.id),
                (InsightRecord.databaseTableName, insight.id),
                (GlossaryTermRecord.databaseTableName, glossary.id),
            ] {
                #expect(throws: DatabaseError.self) {
                    try fixture.manager.dbQueue.write { db in
                        try db.execute(
                            sql: "UPDATE \(table) SET vaultId = ? WHERE id = ?",
                            arguments: [fixture.otherVault.id, id]
                        )
                    }
                }
            }

            try fixture.repository.deleteVault(id: fixture.vault.id)
            let counts = try fixture.manager.dbQueue.read { db in
                try (
                    vaults: VaultRecord.filter(key: fixture.vault.id).fetchCount(db),
                    organizations: OrganizationRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    contacts: ContactRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    domains: OrganizationDomainRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    memberships: OrganizationMembershipRecord.fetchCount(db),
                    meetings: MeetingRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    meetingParticipants: MeetingParticipantRecord.fetchCount(db),
                    projects: ProjectRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    projectReferences: ProjectResourceReferenceRecord.fetchCount(db),
                    insights: InsightRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    insightReferences: InsightReferenceRecord.fetchCount(db),
                    glossaryTerms: GlossaryTermRecord.filter(Column("vaultId") == fixture.vault.id).fetchCount(db),
                    glossaryReferences: GlossaryTermReferenceRecord.fetchCount(db),
                    foreignKeyFailures: Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                )
            }
            #expect(counts.vaults == 0)
            #expect(counts.organizations == 0)
            #expect(counts.contacts == 0)
            #expect(counts.domains == 0)
            #expect(counts.memberships == 0)
            #expect(counts.meetings == 0)
            #expect(counts.meetingParticipants == 0)
            #expect(counts.projects == 0)
            #expect(counts.projectReferences == 0)
            #expect(counts.insights == 0)
            #expect(counts.insightReferences == 0)
            #expect(counts.glossaryTerms == 0)
            #expect(counts.glossaryReferences == 0)
            #expect(counts.foreignKeyFailures.isEmpty)
        }

        @Test
        func duplicateReferenceAPIsReturnPersistedRowsAndDefinitionsMustBeNonblank() throws {
            let fixture = try CustomerIntelligenceFixture()
            let contact = try fixture.repository.upsertContact(
                vaultId: fixture.vault.id,
                email: "owner@acme.example",
                displayName: "Owner"
            )
            let insight = try fixture.repository.createInsight(
                vaultId: fixture.vault.id,
                content: "Owner is the sponsor"
            )
            let glossary = try fixture.repository.createGlossaryTerm(
                vaultId: fixture.vault.id,
                term: "DRI",
                definition: "Directly responsible individual"
            )
            let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
            let laterDate = firstDate.addingTimeInterval(60)

            let firstInsightReference = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: contact.id,
                role: .evidence,
                createdAt: firstDate
            )
            let duplicateInsightReference = try fixture.repository.addInsightReference(
                insightId: insight.id,
                resourceType: .contact,
                resourceId: contact.id,
                role: .evidence,
                createdAt: laterDate
            )
            let firstGlossaryReference = try fixture.repository.addGlossaryTermReference(
                glossaryTermId: glossary.id,
                resourceType: .contact,
                resourceId: contact.id,
                createdAt: firstDate
            )
            let duplicateGlossaryReference = try fixture.repository.addGlossaryTermReference(
                glossaryTermId: glossary.id,
                resourceType: .contact,
                resourceId: contact.id,
                createdAt: laterDate
            )

            #expect(duplicateInsightReference == firstInsightReference)
            #expect(duplicateGlossaryReference == firstGlossaryReference)
            #expect(throws: CustomerIntelligenceError.invalidDefinition) {
                try fixture.repository.createGlossaryTerm(
                    vaultId: fixture.vault.id,
                    term: "Empty",
                    definition: " \n "
                )
            }
        }
    }

    @MainActor
    struct CustomerIntelligenceIngestionRegressionTests {
        @Test
        func resolvingExistingCalendarMeetingRefreshesParticipantsWithoutRecording() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let event = customerIntelligenceEvent(
                at: observedAt,
                participants: [
                    customerParticipant(
                        email: "owner@acme.example",
                        responseStatus: .accepted,
                        source: CalendarEventPlatform.googleCalendar
                    ),
                ]
            )
            let key = try #require(event.key)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                projectId: nil,
                name: "Existing customer sync",
                status: .ready,
                duration: nil,
                createdAt: observedAt.addingTimeInterval(-600),
                updatedAt: observedAt.addingTimeInterval(-600),
                calendarEventIcalUid: key.icalUid,
                calendarEventRecurrenceId: key.recurrenceId
            )
            try await fixture.manager.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: observedAt, in: db)
                try meeting.insert(db)
            }

            let resolvedMeetingID = try fixture.repository.resolveMeetingIdForCalendarEvent(
                event,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                customerIntelligenceIngestion: .afterMeetingPersistence
            )

            #expect(resolvedMeetingID == meeting.id)
            try await waitForParticipant(meetingID: meeting.id, dbQueue: fixture.manager.dbQueue)
            let contact = try #require(
                fixture.repository.fetchContacts(vaultId: fixture.vault.id).first
            )
            let participant = try await fixture.manager.dbQueue.read { db in
                try MeetingParticipantRecord
                    .filter(Column("meetingId") == meeting.id && Column("contactId") == contact.id)
                    .fetchOne(db)
            }
            #expect(contact.email == "owner@acme.example")
            #expect(participant?.responseStatus == .accepted)
            #expect(participant?.updatedAt == observedAt)
        }

        @Test
        func resolvingExistingCalendarMeetingCanDeferParticipantsUntilRecordingStarts() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let event = customerIntelligenceEvent(
                at: observedAt,
                participants: [
                    customerParticipant(
                        email: "owner@acme.example",
                        responseStatus: .accepted,
                        source: CalendarEventPlatform.googleCalendar
                    ),
                ]
            )
            let key = try #require(event.key)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                projectId: nil,
                name: "Existing customer sync",
                status: .ready,
                duration: nil,
                createdAt: observedAt.addingTimeInterval(-600),
                updatedAt: observedAt.addingTimeInterval(-600),
                calendarEventIcalUid: key.icalUid,
                calendarEventRecurrenceId: key.recurrenceId
            )
            try await fixture.manager.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: observedAt, in: db)
                try meeting.insert(db)
            }

            let resolvedMeetingID = try fixture.repository.resolveMeetingIdForCalendarEvent(
                event,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                customerIntelligenceIngestion: .afterCaptureStarts
            )

            #expect(resolvedMeetingID == meeting.id)
            #expect(try fixture.repository.fetchContacts(vaultId: fixture.vault.id).isEmpty)

            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event,
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                dbQueue: fixture.manager.dbQueue
            )
            #expect(
                try fixture.repository.fetchContacts(vaultId: fixture.vault.id).map(\.email)
                    == ["owner@acme.example"]
            )
        }

        @Test
        // swiftlint:disable:next function_body_length
        func reingestionPreservesKnownParticipantDataAndDeclinesAreNotInteractions() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let firstObservation = Date(timeIntervalSince1970: 1_800_000_000)
            let laterObservation = firstObservation.addingTimeInterval(60)
            let olderObservation = firstObservation.addingTimeInterval(-60)

            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: customerIntelligenceEvent(
                    at: firstObservation,
                    participants: [
                        customerParticipant(
                            email: "alice@acme.example",
                            role: .required,
                            responseStatus: .accepted,
                            source: "google"
                        ),
                        customerParticipant(
                            email: "bob@acme.example",
                            role: .optional,
                            responseStatus: .declined,
                            source: "google"
                        ),
                        customerParticipant(
                            email: "me@self.example",
                            isCurrentUser: true,
                            source: "google"
                        ),
                        customerParticipant(
                            email: "ME@SELF.EXAMPLE",
                            source: "eventkit"
                        ),
                    ]
                ),
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: firstObservation,
                dbQueue: fixture.manager.dbQueue
            )
            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: customerIntelligenceEvent(
                    at: laterObservation,
                    participants: [
                        customerParticipant(
                            email: "alice@acme.example",
                            role: .unknown,
                            responseStatus: .unknown,
                            source: "eventkit"
                        ),
                    ]
                ),
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: laterObservation,
                dbQueue: fixture.manager.dbQueue
            )
            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: customerIntelligenceEvent(
                    at: olderObservation,
                    participants: [
                        customerParticipant(
                            email: "alice@acme.example",
                            role: .optional,
                            responseStatus: .declined,
                            source: "stale"
                        ),
                    ]
                ),
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: olderObservation,
                dbQueue: fixture.manager.dbQueue
            )

            let contacts = try fixture.repository.fetchContacts(vaultId: fixture.vault.id)
            #expect(contacts.map(\.email) == ["alice@acme.example", "bob@acme.example"])
            let alice = try #require(contacts.first { $0.email == "alice@acme.example" })
            let bob = try #require(contacts.first { $0.email == "bob@acme.example" })
            let result = try await fixture.manager.dbQueue.read { db in
                try (
                    MeetingParticipantRecord
                        .filter(Column("meetingId") == meeting.id && Column("contactId") == alice.id)
                        .fetchOne(db),
                    MeetingParticipantRecord
                        .filter(Column("meetingId") == meeting.id && Column("contactId") == bob.id)
                        .fetchOne(db)
                )
            }
            let aliceParticipant = try #require(result.0)
            #expect(aliceParticipant.role == .required)
            #expect(aliceParticipant.responseStatus == .accepted)
            #expect(aliceParticipant.source == "eventkit")
            #expect(aliceParticipant.updatedAt == laterObservation)
            #expect(result.1?.responseStatus == .declined)

            let aliceOverviewRecord = try fixture.repository.fetchContactOverview(
                id: alice.id,
                vaultId: fixture.vault.id
            )
            let bobOverviewRecord = try fixture.repository.fetchContactOverview(
                id: bob.id,
                vaultId: fixture.vault.id
            )
            let aliceOverview = try #require(aliceOverviewRecord)
            let bobOverview = try #require(bobOverviewRecord)
            let organization = try #require(
                fixture.repository.fetchOrganizations(vaultId: fixture.vault.id).first
            )
            let domain = try #require(
                fixture.repository.fetchOrganizationDomains(
                    organizationId: organization.id,
                    vaultId: fixture.vault.id
                ).first
            )
            #expect(aliceOverview.meetingCount == 1)
            let lastInteractionAt = try #require(aliceOverview.lastInteractionAt)
            #expect(abs(lastInteractionAt.timeIntervalSince(meeting.createdAt)) < 0.001)
            #expect(lastInteractionAt != firstObservation)
            #expect(bobOverview.meetingCount == 0)
            #expect(bobOverview.lastInteractionAt == nil)
            #expect(domain.firstObservedAt == olderObservation)
            #expect(domain.lastObservedAt == laterObservation)
        }

        private func waitForParticipant(meetingID: UUID, dbQueue: DatabaseQueue) async throws {
            for _ in 0 ..< 200 {
                let count = try await dbQueue.read { db in
                    try MeetingParticipantRecord
                        .filter(Column("meetingId") == meetingID)
                        .fetchCount(db)
                }
                if count == 1 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for existing Meeting participant ingestion")
        }
    }

    private func customerIntelligenceEvent(
        at date: Date,
        participants: [CalendarParticipant]
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            calendarID: "calendar",
            calendarName: "Work",
            calendarColorHex: nil,
            platformId: UUID().uuidString,
            title: "Customer sync",
            description: "",
            icalUid: "customer@example.com",
            startDate: date,
            endDate: date.addingTimeInterval(1800),
            isAllDay: false,
            participants: participants,
            conferenceURI: nil
        )
    }

    private func customerParticipant(
        email: String,
        role: MeetingParticipantRole = .required,
        responseStatus: MeetingParticipantResponseStatus = .accepted,
        isCurrentUser: Bool = false,
        source: String
    ) -> CalendarParticipant {
        CalendarParticipant(
            email: email,
            displayName: nil,
            role: role,
            responseStatus: responseStatus,
            kind: .person,
            isCurrentUser: isCurrentUser,
            source: source
        )
    }
#endif
