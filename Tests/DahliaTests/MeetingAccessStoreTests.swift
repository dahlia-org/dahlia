@testable import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingAccessStoreTests {
        @Test
        func querySearchesMetadataPaginatesAndNeverCrossesVaults() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.queryMeetings(MeetingQuery(limit: 1))
            #expect(firstPage.vault.id == fixture.primaryVaultID)
            #expect(firstPage.meetings.count == 1)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.queryMeetings(MeetingQuery(limit: 1, cursor: cursor))
            #expect(secondPage.meetings.count == 1)
            #expect(Set(firstPage.meetings.map(\.id) + secondPage.meetings.map(\.id)) == fixture.primaryMeetingIDs)

            let calendarMatch = try store.queryMeetings(MeetingQuery(query: "Roadmap"))
            #expect(calendarMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let descriptionMatch = try store.queryMeetings(MeetingQuery(query: "planning decisions"))
            #expect(descriptionMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let tagMatch = try store.queryMeetings(MeetingQuery(query: "launch-tag"))
            #expect(tagMatch.meetings.map(\.id) == [fixture.firstMeetingID])
            let literalWildcardMatch = try store.queryMeetings(MeetingQuery(query: "%"))
            #expect(literalWildcardMatch.meetings.map(\.id) == [fixture.secondMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(query: "_")).meetings.isEmpty)
            let projectMatch = try store.queryMeetings(MeetingQuery(project: "Acme"))
            #expect(projectMatch.meetings.count == 2)
            #expect(try store.queryMeetings(MeetingQuery(query: "secret body")).meetings.isEmpty)
            #expect(!firstPage.meetings.contains { $0.id == fixture.otherVaultMeetingID })

            let otherStore = try fixture.store(vaultID: fixture.otherVaultID)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try otherStore.queryMeetings(MeetingQuery(cursor: cursor))
            }
        }

        @Test
        func meetingReturnsSummaryAndCrossVaultIDsAreNotFound() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let detail = try store.meeting(id: fixture.firstMeetingID)
            #expect(detail.meeting.name == "AI planning title")
            #expect(detail.meeting.description == "Product planning decisions")
            #expect(detail.meeting.calendarTitle == "Roadmap review")
            #expect(detail.summary == "# AI planning title\n\n## Summary\n\nMarkdown secret body")
            #expect(detail.meeting.transcriptSegmentCount == 2)
            #expect(try store.meeting(id: fixture.secondMeetingID).summary == nil)
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.meeting(id: fixture.otherVaultMeetingID)
            }
        }

        @Test
        func transcriptReturnsOnlyConfirmedOriginalTextAndSessionElapsedTime() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.transcript(meetingID: fixture.firstMeetingID, limit: 1)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.transcript(
                meetingID: fixture.firstMeetingID,
                limit: 1,
                cursor: cursor
            )
            let segments = firstPage.segments + secondPage.segments
            let segment = try #require(segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.text == "Original secret body")
            #expect(segment.speaker == "mic")
            #expect(segment.elapsedSeconds == 15)
            #expect(Set(segments.map(\.id)) == [fixture.firstSegmentID, fixture.secondSegmentID])
            #expect(secondPage.nextCursor == nil)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.transcript(meetingID: fixture.secondMeetingID, cursor: cursor)
            }
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.transcript(meetingID: fixture.otherVaultMeetingID)
            }
        }

        @Test
        func relatedRecordsCannotCrossTheVaultBoundary() throws {
            let fixture = try Fixture()
            try fixture.corruptPrimaryProjectAssociation()
            try fixture.corruptPrimarySessionAssociation()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let detail = try store.meeting(id: fixture.firstMeetingID)
            #expect(detail.meeting.project == nil)
            #expect(try store.queryMeetings(MeetingQuery(query: "Other vault project")).meetings.isEmpty)
            let transcript = try store.transcript(meetingID: fixture.firstMeetingID)
            let segment = try #require(transcript.segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.elapsedSeconds == 0)
        }

        @Test
        func mcpProtocolRequiresInitializationAndReportsScopedVaultErrors() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let server = DahliaMCPServer(store: store)

            let preInitialize = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"query_meetings","arguments":{}}}
            """#))
            #expect((preInitialize["error"] as? [String: Any])?["code"] as? Int == -32002)

            let initialized = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#))
            #expect((initialized["result"] as? [String: Any])?["serverInfo"] != nil)
            let instructions = (initialized["result"] as? [String: Any])?["instructions"] as? String
            #expect(instructions?.contains("Primary") == false)
            #expect(instructions?.contains("untrusted data") == true)
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(definitions.map { $0["name"] as? String } == [
                "query_meetings", "get_meeting", "get_meeting_transcript",
            ])
            #expect((definitions.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)

            let queryCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning"}}}
            """#))
            let queryResult = try #require(queryCall["result"] as? [String: Any])
            #expect(queryResult["isError"] as? Bool == false)
            #expect((queryResult["structuredContent"] as? [String: Any])?["meetings"] != nil)

            let meetingCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture.firstMeetingID
                .uuidString)"}}}
            """#))
            #expect(((meetingCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["summary"] as? String ==
                "# AI planning title\n\n## Summary\n\nMarkdown secret body")

            let transcriptCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","limit":1}}}
            """#))
            let transcriptContent = ((transcriptCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            #expect(transcriptContent?["segments"] != nil)
            #expect(transcriptContent?["next_cursor"] is String)

            let invalid = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"unexpected":true}}}
            """#))
            #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32602)
            let unknown = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unknown","arguments":{}}}
            """#))
            #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
            let nonObjectArguments = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"query_meetings","arguments":"invalid"}}
            """#))
            #expect((nonObjectArguments["error"] as? [String: Any])?["code"] as? Int == -32602)
            let invalidVersion = try Self.json(server.handleLine(#"""
            {"jsonrpc":"1.0","id":11,"method":"ping"}
            """#))
            #expect((invalidVersion["error"] as? [String: Any])?["code"] as? Int == -32600)

            let missingVaultStore = try fixture.store(vaultID: UUID.v7())
            let missingVaultServer = DahliaMCPServer(store: missingVaultStore)
            let missing = try Self.json(missingVaultServer.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{}}"#))
            #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32000)
        }

        @Test
        func oldDatabaseRequiresOpeningDahliaForMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v18-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vaultID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT NOT NULL)")
                try db.execute(sql: "CREATE TABLE meetings (id BLOB PRIMARY KEY, vaultId BLOB NOT NULL, name TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO vaults (id, name) VALUES (?, ?)", arguments: [vaultID, "Old"])
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        @Test
        func v20SummaryColumnsRequireOpeningDahliaForMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-v20-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let vaultID = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT NOT NULL)")
                try db.execute(sql: "CREATE TABLE meetings (id BLOB PRIMARY KEY, description TEXT NOT NULL)")
                try db.execute(
                    sql: """
                    CREATE TABLE summaries (
                        meetingId BLOB PRIMARY KEY,
                        title TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        document TEXT,
                        googleFileId TEXT,
                        vaultRelativePath TEXT,
                        createdAt DATETIME NOT NULL
                    )
                    """
                )
                try db.execute(sql: "INSERT INTO vaults (id, name) VALUES (?, ?)", arguments: [vaultID, "Old"])
            }
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)

            #expect(throws: MeetingAccessError.databaseUpgradeRequired) {
                try store.scopedVault()
            }
        }

        @Test
        func invalidSummaryDocumentReturnsDedicatedError() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = 'not-json' WHERE meetingId = ?",
                    arguments: [fixture.firstMeetingID]
                )
            }

            #expect(throws: MeetingAccessError.invalidSummaryDocument) {
                try fixture.store(vaultID: fixture.primaryVaultID).meeting(id: fixture.firstMeetingID)
            }
        }

        @Test
        func storedDocumentRendererGeneratesGenericMarkdownForAllBlocks() throws {
            let document = SummaryDocument(
                title: "Release plan",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Decision",
                        blocks: [
                            .paragraph("Ship it", transcriptRef: TranscriptReference(time: "00:00:01")),
                            .bulletedList(items: ["Alpha", "Beta"]),
                            .numberedList(items: ["First", "Second"]),
                            .checklist(items: [
                                .init(text: "Done", checked: true),
                                .init(text: "Pending", checked: false),
                            ]),
                            .quote("Quoted"),
                            .code(language: "swift\n```evil", code: "let value = 1\n```breakout"),
                            .image(screenshotId: .v7(), caption: "Screenshot"),
                            .image(screenshotId: .v7(), caption: ""),
                            .heading(level: 4, text: "Details"),
                            .table(headers: ["Name", "State"], rows: [["A|B", "Ready\nNow"]]),
                        ]
                    ),
                ],
                actionItems: [SummaryActionItem(title: "Follow up", assignee: "Mina")]
            )

            let markdown = try StoredSummaryDocumentMarkdownRenderer.render(json: document.databaseJSONString())

            #expect(markdown == """
            # Release plan

            ## Decision

            Ship it

            - Alpha
            - Beta

            1. First
            2. Second

            - [x] Done
            - [ ] Pending

            > Quoted

            ````swiftevil
            let value = 1
            ```breakout
            ````

            Screenshot

            #### Details

            | Name | State |
            | --- | --- |
            | A\\|B | Ready<br>Now |

            ## Action Items
            - [ ] Follow up (Mina)
            """)
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @MainActor
    private final class Fixture {
        let databaseURL: URL
        let manager: AppDatabaseManager
        let primaryVaultID = UUID.v7()
        let otherVaultID = UUID.v7()
        let firstMeetingID = UUID.v7()
        let secondMeetingID = UUID.v7()
        let otherVaultMeetingID = UUID.v7()
        let firstSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let otherVaultProjectID = UUID.v7()
        let otherVaultSessionID = UUID.v7()
        var primaryMeetingIDs: Set<UUID> { [firstMeetingID, secondMeetingID] }

        init() throws {
            databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            manager = try AppDatabaseManager(path: databaseURL.path)
            let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            let projectID = UUID.v7()
            let sessionID = UUID.v7()

            try manager.dbQueue.write { db in
                try insertMetadata(in: db, createdAt: createdAt, projectID: projectID)
                try insertContent(in: db, createdAt: createdAt, sessionID: sessionID)
            }
        }

        private func insertMetadata(in db: Database, createdAt: Date, projectID: UUID) throws {
            for vault in [
                VaultRecord(id: primaryVaultID, path: "/tmp/primary", name: "Primary", createdAt: createdAt, lastOpenedAt: createdAt),
                VaultRecord(id: otherVaultID, path: "/tmp/other", name: "Other", createdAt: createdAt, lastOpenedAt: createdAt),
            ] {
                try vault.insert(db)
            }
            try ProjectRecord(id: projectID, vaultId: primaryVaultID, name: "Acme", createdAt: createdAt).insert(db)
            try ProjectRecord(
                id: otherVaultProjectID,
                vaultId: otherVaultID,
                name: "Other vault project",
                createdAt: createdAt
            ).insert(db)
            try insertCalendarEvent(in: db, createdAt: createdAt)
            try insertMeetings(in: db, createdAt: createdAt, projectID: projectID)
        }

        private func insertCalendarEvent(in db: Database, createdAt: Date) throws {
            try CalendarEventRecord(
                now: createdAt,
                event: CalendarEvent(
                    id: "calendar-item",
                    calendarID: "work",
                    calendarName: "Work",
                    calendarColorHex: "#000000",
                    platformId: "calendar-item",
                    title: "Roadmap review",
                    description: "Calendar description",
                    icalUid: "roadmap@example.com",
                    recurrenceId: "",
                    startDate: createdAt,
                    endDate: createdAt.addingTimeInterval(3600),
                    isAllDay: false,
                    conferenceURI: nil
                ),
                key: CalendarEventKey(icalUid: "roadmap@example.com", recurrenceId: "")
            ).insert(db)
        }

        private func insertMeetings(in db: Database, createdAt: Date, projectID: UUID) throws {
            try MeetingRecord(
                id: firstMeetingID,
                vaultId: primaryVaultID,
                projectId: projectID,
                name: "AI planning title",
                description: "Product planning decisions",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(20),
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
            try MeetingRecord(
                id: secondMeetingID,
                vaultId: primaryVaultID,
                projectId: projectID,
                name: "Budget 100% review",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(10),
                updatedAt: createdAt
            ).insert(db)
            let tag = TagRecord(name: "launch-tag", colorHex: "#808080", createdAt: createdAt)
            try tag.insert(db)
            try MeetingTagRecord(meetingId: firstMeetingID, tagId: db.lastInsertedRowID).insert(db)
            try MeetingRecord(
                id: otherVaultMeetingID,
                vaultId: otherVaultID,
                projectId: nil,
                name: "Other vault",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(30),
                updatedAt: createdAt
            ).insert(db)
        }

        private func insertContent(in db: Database, createdAt: Date, sessionID: UUID) throws {
            try SummaryRecord(
                meetingId: firstMeetingID,
                title: "AI planning title",
                document: SummaryDocument(
                    title: "AI planning title",
                    sections: [
                        SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Markdown secret body")]),
                    ]
                ).databaseJSONString(),
                createdAt: createdAt
            ).insert(db)
            try RecordingSessionRecord(
                id: sessionID,
                meetingId: firstMeetingID,
                startedAt: createdAt,
                endedAt: createdAt.addingTimeInterval(20),
                duration: 20,
                offsetSeconds: 10,
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
            try RecordingSessionRecord(
                id: otherVaultSessionID,
                meetingId: otherVaultMeetingID,
                startedAt: createdAt,
                endedAt: createdAt.addingTimeInterval(20),
                duration: 20,
                offsetSeconds: 1000,
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
            try TranscriptSegmentRecord(
                id: firstSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(7),
                text: "Original secret body",
                translatedText: "Translated text",
                isConfirmed: true,
                speakerLabel: "mic"
            ).insert(db)
            try TranscriptSegmentRecord(
                id: secondSegmentID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(5),
                endTime: createdAt.addingTimeInterval(8),
                text: "Second original body",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "system"
            ).insert(db)
            try TranscriptSegmentRecord(
                id: .v7(),
                meetingId: firstMeetingID,
                sessionId: sessionID,
                startTime: createdAt.addingTimeInterval(8),
                text: "Unconfirmed text",
                translatedText: nil,
                isConfirmed: false,
                speakerLabel: nil
            ).insert(db)
        }

        deinit {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        func store(vaultID: UUID) throws -> MeetingAccessStore {
            try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)
        }

        func corruptPrimaryProjectAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET projectId = ? WHERE id = ?",
                    arguments: [otherVaultProjectID, firstMeetingID]
                )
            }
        }

        func corruptPrimarySessionAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET sessionId = ? WHERE id = ?",
                    arguments: [otherVaultSessionID, firstSegmentID]
                )
            }
        }
    }
#endif
