import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CustomerIntelligenceCaptionViewModelTests {
        @Test
        func materializedCalendarDraftSchedulesParticipantIngestion() async throws {
            let fixture = try CustomerIntelligenceFixture()
            let viewModel = CaptionViewModel()
            let vaultURL = try #require(fixture.vault.url)
            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = fixture.vault
            defer { AppSettings.shared.currentVault = previousVault }

            let event = CalendarEvent(
                id: "calendar::customer-event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "customer-event",
                title: "Customer sync",
                description: "",
                icalUid: "customer-event@example.com",
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_003_600),
                isAllDay: false,
                participants: [
                    CalendarParticipant(
                        email: "owner@acme.example",
                        displayName: "Owner",
                        role: .required,
                        responseStatus: .accepted,
                        kind: .person,
                        isCurrentUser: false,
                        source: CalendarEventPlatform.googleCalendar
                    ),
                ],
                conferenceURI: nil
            )
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: fixture.manager.dbQueue,
                vaultURL: vaultURL
            )

            let meetingID = try #require(
                viewModel.materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence)
            )
            try await waitForParticipant(meetingID: meetingID, dbQueue: fixture.manager.dbQueue)
            let contact = try await fixture.manager.dbQueue.read { db in
                try ContactRecord.fetchOne(db)
            }

            #expect(contact?.email == "owner@acme.example")
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
            Issue.record("Timed out waiting for customer intelligence ingestion")
        }
    }
#endif
