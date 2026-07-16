import Foundation
@testable import Dahlia

@MainActor
struct PreviousSummaryTestFixture {
    let manager: AppDatabaseManager
    let repository: MeetingRepository
    let vault: VaultRecord
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        manager = try AppDatabaseManager(path: ":memory:")
        repository = MeetingRepository(dbQueue: manager.dbQueue)
        vault = VaultRecord(
            id: .v7(),
            path: "/tmp/previous-summary-tests",
            name: "Test Vault",
            createdAt: baseDate,
            lastOpenedAt: baseDate
        )
        try repository.insertVault(vault)
    }

    func insertMeeting(
        name: String,
        icalUid: String?,
        recurrenceId: String?,
        start: Date,
        recordedAt: Date? = nil,
        vaultId: UUID? = nil,
        summary: SummaryDocument? = nil,
        invalidSummary: Bool = false
    ) throws -> MeetingRecord {
        if let icalUid, let recurrenceId {
            try insertCalendarEvent(
                name: name,
                icalUid: icalUid,
                recurrenceId: recurrenceId,
                start: start
            )
        }

        let recordedAt = recordedAt ?? start
        let meeting = MeetingRecord(
            id: .v7(),
            vaultId: vaultId ?? vault.id,
            projectId: nil,
            name: name,
            createdAt: recordedAt,
            updatedAt: recordedAt,
            calendarEventIcalUid: icalUid,
            calendarEventRecurrenceId: recurrenceId
        )
        try manager.dbQueue.write { db in
            try meeting.insert(db)
        }
        if let summary {
            try repository.upsertSummary(SummaryRecord(
                meetingId: meeting.id,
                title: summary.title,
                document: try summary.databaseJSONString(),
                createdAt: recordedAt
            ))
        } else if invalidSummary {
            try repository.upsertSummary(SummaryRecord(
                meetingId: meeting.id,
                title: "Corrupt",
                document: "not-json",
                createdAt: recordedAt
            ))
        }
        return meeting
    }

    func insertVault(name: String) throws -> VaultRecord {
        let vault = VaultRecord(
            id: .v7(),
            path: "/tmp/previous-summary-tests-\(UUID().uuidString)",
            name: name,
            createdAt: baseDate,
            lastOpenedAt: baseDate
        )
        try repository.insertVault(vault)
        return vault
    }

    private func insertCalendarEvent(
        name: String,
        icalUid: String,
        recurrenceId: String,
        start: Date
    ) throws {
        let event = CalendarEvent(
            id: recurrenceId,
            calendarID: "work",
            calendarName: "Work",
            calendarColorHex: "#000000",
            platformId: recurrenceId,
            title: name,
            description: "",
            icalUid: icalUid,
            recurrenceId: recurrenceId,
            startDate: start,
            endDate: start.addingTimeInterval(3_600),
            isAllDay: false,
            conferenceURI: nil
        )
        try manager.dbQueue.write { db in
            try CalendarEventRecord.upsert(event: event, now: baseDate, in: db)
        }
    }
}
