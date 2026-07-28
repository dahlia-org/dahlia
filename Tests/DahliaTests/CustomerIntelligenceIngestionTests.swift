import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceIngestionTests {
        @Test
        // swiftlint:disable:next function_body_length
        func calendarIngestionIsIdempotentAndCreatesOnlyBusinessOrganizations() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let event = CalendarEvent(
                id: "event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "event",
                title: "Customer sync",
                description: "",
                icalUid: "event@example.com",
                startDate: observedAt,
                endDate: observedAt.addingTimeInterval(1800),
                isAllDay: false,
                participants: [
                    CalendarParticipant(
                        email: " Alice@Acme.COM ",
                        displayName: "Alice",
                        role: .required,
                        responseStatus: .accepted,
                        kind: .person,
                        isCurrentUser: false,
                        source: "google"
                    ),
                    CalendarParticipant(
                        email: "alice@acme.com",
                        displayName: nil,
                        role: .unknown,
                        responseStatus: .unknown,
                        kind: .person,
                        isCurrentUser: false,
                        source: "eventkit"
                    ),
                    CalendarParticipant(
                        email: "personal@gmail.com",
                        displayName: "Personal",
                        role: .optional,
                        responseStatus: .tentative,
                        kind: .person,
                        isCurrentUser: false,
                        source: "google"
                    ),
                    CalendarParticipant(
                        email: "me@dahlia.local",
                        displayName: "Me",
                        role: .organizer,
                        responseStatus: .accepted,
                        kind: .person,
                        isCurrentUser: true,
                        source: "google"
                    ),
                    CalendarParticipant(
                        email: "room@acme.com",
                        displayName: "Room",
                        role: .required,
                        responseStatus: .accepted,
                        kind: .room,
                        isCurrentUser: false,
                        source: "google"
                    ),
                    CalendarParticipant(
                        email: "利用者@acme.com",
                        displayName: "Invalid",
                        role: .required,
                        responseStatus: .accepted,
                        kind: .person,
                        isCurrentUser: false,
                        source: "google"
                    ),
                ],
                conferenceURI: nil
            )

            let firstMetrics = try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event,
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                dbQueue: fixture.manager.dbQueue
            )
            let secondMetrics = try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event,
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt.addingTimeInterval(60),
                dbQueue: fixture.manager.dbQueue
            )

            let expectedMetrics = CustomerIntelligenceIngestionMetrics(
                observedParticipantCount: 6,
                ingestedContactCount: 2,
                skippedNonPersonCount: 1,
                skippedInvalidEmailCount: 1,
                excludedCurrentUserIdentityCount: 1,
                deduplicatedParticipantCount: 1
            )
            #expect(firstMetrics == expectedMetrics)
            #expect(secondMetrics == expectedMetrics)

            let result = try await fixture.manager.dbQueue.read { db in
                let contacts = try ContactRecord
                    .filter(Column("vaultId") == fixture.vault.id)
                    .order(Column("email"))
                    .fetchAll(db)
                let organizations = try OrganizationRecord
                    .filter(Column("vaultId") == fixture.vault.id)
                    .fetchAll(db)
                let domains = try OrganizationDomainRecord
                    .filter(Column("vaultId") == fixture.vault.id)
                    .fetchAll(db)
                let memberships = try OrganizationMembershipRecord.fetchAll(db)
                let participants = try MeetingParticipantRecord
                    .filter(Column("meetingId") == meeting.id)
                    .fetchAll(db)
                return (contacts, organizations, domains, memberships, participants)
            }

            #expect(result.0.map(\.email) == ["alice@acme.com", "personal@gmail.com"])
            #expect(result.0.map(\.displayName) == ["alice", "personal"])
            #expect(result.1.map(\.name) == ["acme.com"])
            #expect(result.2.map(\.domainName) == ["acme.com"])
            #expect(result.2.first?.isPrimary == true)
            #expect(result.3.count == 1)
            #expect(result.4.count == 2)
            let alice = try #require(result.0.first)
            let aliceParticipant = try #require(result.4.first(where: { $0.contactId == alice.id }))
            #expect(aliceParticipant.role == MeetingParticipantRole.required)
            #expect(aliceParticipant.responseStatus == MeetingParticipantResponseStatus.accepted)
        }

        @Test
        func automaticOrganizationsUseTheCompleteEmailDomain() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let event = CalendarEvent(
                id: "event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "event",
                title: "Customer sync",
                description: "",
                icalUid: "event@example.com",
                startDate: observedAt,
                endDate: observedAt.addingTimeInterval(1800),
                isAllDay: false,
                participants: [
                    participant(email: "one@mail.example.co.jp"),
                    participant(email: "two@example.co.jp"),
                ],
                conferenceURI: nil
            )

            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event,
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                dbQueue: fixture.manager.dbQueue
            )

            let names = try fixture.repository
                .fetchOrganizations(vaultId: fixture.vault.id)
                .map(\.name)
                .sorted()
            #expect(names == ["example.co.jp", "mail.example.co.jp"])
        }

        @Test
        func calendarFreshnessAndParticipantUpdatesIncreaseEntityRevisions() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let meeting = try fixture.insertMeeting()
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            func event(displayName: String?, role: MeetingParticipantRole) -> CalendarEvent {
                CalendarEvent(
                    id: "revision-event",
                    calendarID: "calendar",
                    calendarName: "Work",
                    calendarColorHex: nil,
                    platformId: "revision-event",
                    title: "Revision",
                    description: "",
                    icalUid: "revision@example.com",
                    startDate: observedAt,
                    endDate: observedAt.addingTimeInterval(1800),
                    isAllDay: false,
                    participants: [
                        CalendarParticipant(
                            email: "person@acme.example",
                            displayName: displayName,
                            role: role,
                            responseStatus: .accepted,
                            kind: .person,
                            isCurrentUser: false,
                            source: "google"
                        ),
                    ],
                    conferenceURI: nil
                )
            }

            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event(displayName: nil, role: .unknown),
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt,
                dbQueue: fixture.manager.dbQueue
            )
            let first = try await fixture.manager.dbQueue.read { db in
                let contact = try ContactRecord
                    .filter(Column("vaultId") == fixture.vault.id)
                    .fetchOne(db)
                let organization = try OrganizationRecord
                    .filter(Column("vaultId") == fixture.vault.id)
                    .fetchOne(db)
                return (contact, organization)
            }
            let firstContact = try #require(first.0)
            let firstOrganization = try #require(first.1)
            #expect(firstContact.displayName == "person")

            try await CustomerIntelligenceIngestionService.ingest(
                calendarEvent: event(displayName: "Person", role: .required),
                meetingId: meeting.id,
                vaultId: fixture.vault.id,
                observedAt: observedAt.addingTimeInterval(60),
                dbQueue: fixture.manager.dbQueue
            )
            let second = try await fixture.manager.dbQueue.read { db in
                let contact = try ContactRecord.fetchOne(db, key: firstContact.id)
                let organization = try OrganizationRecord.fetchOne(db, key: firstOrganization.id)
                return (contact, organization)
            }
            let secondContact = try #require(second.0)
            let secondOrganization = try #require(second.1)
            #expect(secondContact.displayName == "person")
            #expect(secondContact.revision == firstContact.revision + 1)
            #expect(secondOrganization.revision == firstOrganization.revision + 1)
        }

        private func participant(email: String) -> CalendarParticipant {
            CalendarParticipant(
                email: email,
                displayName: nil,
                role: .required,
                responseStatus: .accepted,
                kind: .person,
                isCurrentUser: false,
                source: CalendarEventPlatform.googleCalendar
            )
        }
    }
#endif
