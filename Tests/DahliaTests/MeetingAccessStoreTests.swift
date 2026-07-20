import Foundation
import GRDB
import ImageIO
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingAccessStoreTests {
        @Test
        func querySearchesMetadataPaginatesAndNeverCrossesVaults() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.queryMeetings(MeetingQuery(limit: 2))
            #expect(firstPage.vault.id == fixture.primaryVaultID)
            #expect(firstPage.meetings.count == 2)
            let cursor = try #require(firstPage.nextCursor)
            let secondPage = try store.queryMeetings(MeetingQuery(limit: 2, cursor: cursor))
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
            let projectIDMatch = try store.queryMeetings(MeetingQuery(projectID: fixture.primaryProjectID))
            #expect(Set(projectIDMatch.meetings.map(\.id)) == fixture.projectMeetingIDs)
            #expect(Set(projectIDMatch.meetings.compactMap(\.icalUID)) == ["roadmap@example.com", "budget@example.com"])
            let icalUIDMatch = try store.queryMeetings(MeetingQuery(icalUID: " roadmap@example.com "))
            #expect(icalUIDMatch.meetings.map(\.id) == [fixture.firstMeetingID, fixture.recurringMeetingID])
            #expect(try store.queryMeetings(MeetingQuery(
                projectID: fixture.primaryProjectID,
                icalUID: "missing@example.com"
            )).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(projectID: fixture.otherVaultProjectID)).meetings.isEmpty)
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
            #expect(detail.meeting.projectID == fixture.primaryProjectID)
            #expect(detail.meeting.icalUID == "roadmap@example.com")
            #expect(detail.meeting.recurrenceID?.isEmpty == true)
            #expect(detail.meeting.calendarTitle == "Roadmap review")
            #expect(detail.summary?.contains("Markdown secret body [Transcript 00:00:15]") == true)
            #expect(detail.summary?.contains("[Screenshot \(fixture.firstScreenshotID.uuidString) at 00:00:16]") == true)
            guard case let .object(document)? = detail.summaryDocument,
                  case let .array(sections)? = document["sections"],
                  case let .object(section)? = sections.first,
                  case let .array(blocks)? = section["blocks"],
                  case let .object(paragraph)? = blocks.first,
                  case let .object(content)? = paragraph["content"] else {
                Issue.record("Expected a structured summary document")
                return
            }
            #expect(content["transcript_ref"] == .string("00:00:15"))
            #expect(document["schema_version"] == .number(3))
            #expect(document["schemaVersion"] == nil)
            #expect(section["id"] != nil)
            #expect(paragraph["id"] != nil)
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
            #expect(segment.endedElapsedSeconds == 17)
            #expect(segment.timestamp == "00:00:15")
            #expect(Set(segments.map(\.id)) == [fixture.firstSegmentID, fixture.secondSegmentID])
            #expect(secondPage.nextCursor == nil)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.transcript(meetingID: fixture.secondMeetingID, cursor: cursor)
            }
            #expect(throws: MeetingAccessError.meetingNotFound) {
                try store.transcript(meetingID: fixture.otherVaultMeetingID)
            }

            let range = try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 15,
                toElapsedSeconds: 16,
                limit: 1
            )
            #expect(range.segments.count == 1)
            #expect(try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 0,
                toElapsedSeconds: 15
            ).segments.isEmpty)
            let rangeCursor = try #require(range.nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.transcript(
                    meetingID: fixture.firstMeetingID,
                    fromElapsedSeconds: 14,
                    toElapsedSeconds: 16,
                    cursor: rangeCursor
                )
            }
        }

        @Test
        func transcriptEndElapsedSecondsUsesTheSamePrecisionAsStart() throws {
            let fixture = try Fixture()
            let endedAt = Date(timeIntervalSince1970: 1_800_000_007.123_456)
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET endTime = ? WHERE id = ?",
                    arguments: [endedAt, fixture.firstSegmentID]
                )
            }

            let page = try fixture.store(vaultID: fixture.primaryVaultID).transcript(
                meetingID: fixture.firstMeetingID
            )
            let segment = try #require(page.segments.first { $0.id == fixture.firstSegmentID })
            #expect(segment.endedElapsedSeconds == 17.123)
        }

        @Test
        func screenshotsArePagedFilteredAndReturnedOneAtATimeAsResizedImages() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(limit: 1)
            )
            #expect(firstPage.screenshots.count == 1)
            #expect(firstPage.nextCursor != nil)
            let secondPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(limit: 1, cursor: firstPage.nextCursor)
            )
            #expect(Set((firstPage.screenshots + secondPage.screenshots).map(\.id)) == fixture.primaryScreenshotIDs)

            let filtered = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 15, toElapsedSeconds: 17)
            )
            #expect(filtered.screenshots.map(\.id) == [fixture.firstScreenshotID])
            #expect(filtered.screenshots.first?.timestamp == "00:00:16")
            #expect(filtered.screenshots.first?.isReferencedInSummary == true)
            #expect(try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 15, toElapsedSeconds: 16)
            ).screenshots.isEmpty)

            let rangedPage = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 100, limit: 1)
            )
            let rangedCursor = try #require(rangedPage.nextCursor)
            #expect(throws: MeetingAccessError.invalidCursor) {
                try store.screenshots(
                    meetingID: fixture.firstMeetingID,
                    query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 99, cursor: rangedCursor)
                )
            }

            let image = try store.screenshot(
                meetingID: fixture.firstMeetingID,
                screenshotID: fixture.firstScreenshotID
            )
            #expect(image.imageData != fixture.imageData)
            #expect(["image/webp", "image/jpeg"].contains(image.mimeType))
            let source = CGImageSourceCreateWithData(image.imageData as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            #expect((properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) <= 1024)
            #expect((properties?[kCGImagePropertyPixelHeight] as? Int ?? 0) <= 1024)
            #expect(throws: MeetingAccessError.screenshotNotFound) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.otherVaultScreenshotID)
            }
        }

        @Test
        func screenshotImagesAreActuallyDownsampledAndRejectCorruptData() throws {
            let fixture = try Fixture()
            let largeImage = try #require(Self.makeImage(width: 2048, height: 512))
            let largeData = try #require(ImageEncoder.encode(largeImage, quality: 0.9))
            try fixture.updateFirstScreenshot(data: largeData)
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let image = try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.firstScreenshotID)
            let source = try #require(CGImageSourceCreateWithData(image.imageData as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 256)

            try fixture.updateFirstScreenshot(data: Data("not an image".utf8))
            #expect(throws: MeetingAccessError.screenshotEncodingFailed) {
                try store.screenshot(meetingID: fixture.firstMeetingID, screenshotID: fixture.firstScreenshotID)
            }

            let range = try store.screenshotImages(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 0, toElapsedSeconds: 100)
            )
            #expect(range.images.map(\.metadata.id) == [fixture.secondScreenshotID])
            #expect(range.page.screenshots.map(\.id) == [fixture.secondScreenshotID])
        }

        @Test
        func elapsedTimelineUsesOffsetsAcrossPausedRecordingSessions() throws {
            let fixture = try Fixture()
            let inserted = try fixture.insertPausedSessionContent()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let transcript = try store.transcript(
                meetingID: fixture.firstMeetingID,
                fromElapsedSeconds: 35,
                toElapsedSeconds: 36
            )
            #expect(transcript.segments.map(\.id) == [inserted.segmentID])
            #expect(transcript.segments.first?.timestamp == "00:00:35")

            let screenshots = try store.screenshots(
                meetingID: fixture.firstMeetingID,
                query: ScreenshotQuery(fromElapsedSeconds: 36, toElapsedSeconds: 37)
            )
            #expect(screenshots.screenshots.map(\.id) == [inserted.screenshotID])
            #expect(screenshots.screenshots.first?.timestamp == "00:00:36")
        }

        @Test
        func relatedRecordsCannotCrossTheVaultBoundary() throws {
            let fixture = try Fixture()
            try fixture.corruptPrimaryProjectAssociation()
            try fixture.corruptPrimarySessionAssociation()
            try fixture.corruptPrimaryScreenshotSessionAssociation()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let detail = try store.meeting(id: fixture.firstMeetingID)
            #expect(detail.meeting.project == nil)
            #expect(detail.meeting.projectID == nil)
            #expect(try store.queryMeetings(MeetingQuery(query: "Other vault project")).meetings.isEmpty)
            #expect(try store.queryMeetings(MeetingQuery(projectID: fixture.otherVaultProjectID)).meetings.isEmpty)
            let transcript = try store.transcript(meetingID: fixture.firstMeetingID)
            let segment = try #require(transcript.segments.first(where: { $0.id == fixture.firstSegmentID }))
            #expect(segment.elapsedSeconds == 0)
            let screenshots = try store.screenshots(meetingID: fixture.firstMeetingID)
            #expect(screenshots.screenshots.first(where: { $0.id == fixture.firstScreenshotID })?.elapsedSeconds == 0)
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
                "query_meetings", "get_meeting", "get_meeting_transcript", "get_meeting_screenshots",
            ])
            #expect((definitions.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
            #expect(definitions.allSatisfy { $0["outputSchema"] != nil })
            #expect(definitions.allSatisfy {
                ($0["outputSchema"] as? [String: Any])?["additionalProperties"] as? Bool == false
            })

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
            let meetingContent = (meetingCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((meetingContent?["summary"] as? String)?.contains("[Transcript 00:00:15]") == true)
            let summaryDocument = try #require(meetingContent?["summary_document"] as? [String: Any])
            #expect(summaryDocument["schema_version"] as? Int == 3)
            #expect(summaryDocument["schemaVersion"] == nil)
            let sections = try #require(summaryDocument["sections"] as? [[String: Any]])
            let blocks = try #require(sections.first?["blocks"] as? [[String: Any]])
            #expect(sections.first?["id"] is String)
            #expect(blocks.allSatisfy { $0["id"] is String })
            #expect(blocks.contains { $0["screenshot_id"] as? String == fixture.firstScreenshotID.uuidString })

            let transcriptCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","limit":1}}}
            """#))
            let transcriptContent = ((transcriptCall["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
            #expect(transcriptContent?["segments"] != nil)
            #expect(transcriptContent?["next_cursor"] is String)

            let screenshotCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","screenshot_ids":["\#(fixture.firstScreenshotID.uuidString)","\#(fixture.secondScreenshotID
                .uuidString)"]}}}
            """#))
            let screenshotResult = try #require(screenshotCall["result"] as? [String: Any])
            let screenshotContent = try #require(screenshotResult["content"] as? [[String: Any]])
            #expect(screenshotContent.map { $0["type"] as? String } == ["text", "text", "image", "text", "image"])
            #expect((screenshotContent.last?["data"] as? String)?.isEmpty == false)
            let screenshotStructured = try #require(screenshotResult["structuredContent"] as? [String: Any])
            let selectedScreenshots = try #require(screenshotStructured["screenshots"] as? [[String: Any]])
            #expect(selectedScreenshots.compactMap { $0["id"] as? String } == [
                fixture.firstScreenshotID.uuidString,
                fixture.secondScreenshotID.uuidString,
            ])

            let rangedScreenshotCall = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","from_elapsed_seconds":15,"to_elapsed_seconds":17}}}
            """#))
            let rangedContent = ((rangedScreenshotCall["result"] as? [String: Any])?["content"] as? [[String: Any]])
            #expect(rangedContent?.map { $0["type"] as? String } == ["text", "text", "image"])

            let missingSelector = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)"}}}
            """#))
            #expect((missingSelector["error"] as? [String: Any])?["code"] as? Int == -32602)

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
        func screenshotIDSelectorRejectsPaginationArguments() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting_screenshots","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","screenshot_ids":["\#(fixture.firstScreenshotID.uuidString)"],"limit":1}}}
            """#))
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)

            func call(ids: [String]) throws -> [String: Any] {
                let request: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "get_meeting_screenshots",
                        "arguments": ["meeting_id": fixture.firstMeetingID.uuidString, "screenshot_ids": ids],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: request)
                return try Self.json(server.handleLine(String(decoding: data, as: UTF8.self)))
            }

            let invalidSelections = try [
                call(ids: []),
                call(ids: [fixture.firstScreenshotID.uuidString, fixture.firstScreenshotID.uuidString]),
                call(ids: (0 ..< 11).map { _ in UUID.v7().uuidString }),
                call(ids: ["not-a-uuid"]),
            ]
            #expect(invalidSelections.allSatisfy { ($0["error"] as? [String: Any])?["code"] as? Int == -32602 })
        }

        @Test
        func elapsedTimeInputsRejectInvalidRanges() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))
            _ = server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            _ = server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            let response = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_meeting_transcript","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)","from_elapsed_seconds":2,"to_elapsed_seconds":1}}}
            """#))
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
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

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }

        private static func makeImage(width: Int, height: Int) -> CGImage? {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

    }

    @MainActor
    struct MCPDiscoveryContractTests {
        @Test
        func exposesRelationshipKeys() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(store: fixture.store(vaultID: fixture.primaryVaultID))

            let initialized = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            let instructions = try #require((initialized["result"] as? [String: Any])?["instructions"] as? String)
            #expect(instructions.contains("ical_uid"))
            #expect(instructions.contains("project_id"))
            #expect(instructions.contains("transcripts or screenshots only when supporting evidence is needed"))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let queryDefinition = try #require(definitions.first { $0["name"] as? String == "query_meetings" })
            let inputSchema = try #require(queryDefinition["inputSchema"] as? [String: Any])
            let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
            #expect(inputProperties["ical_uid"] != nil)
            #expect(inputProperties["project_id"] != nil)
            let outputSchema = try #require(queryDefinition["outputSchema"] as? [String: Any])
            let outputProperties = try #require(outputSchema["properties"] as? [String: Any])
            let meetingsSchema = try #require(outputProperties["meetings"] as? [String: Any])
            let meetingSchema = try #require(meetingsSchema["items"] as? [String: Any])
            let meetingProperties = try #require(meetingSchema["properties"] as? [String: Any])
            #expect(meetingProperties["project_id"] != nil)
            #expect(meetingProperties["ical_uid"] != nil)
            #expect(meetingProperties["recurrence_id"] != nil)

            let metadataQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_meetings","arguments":{"query":"planning"}}}
            """#))
            let metadataContent = (metadataQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let meeting = try #require((metadataContent?["meetings"] as? [[String: Any]])?.first)
            #expect(meeting["project_id"] as? String == fixture.primaryProjectID.uuidString)
            #expect(meeting["ical_uid"] as? String == "roadmap@example.com")
            #expect((meeting["recurrence_id"] as? String)?.isEmpty == true)

            let projectQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"\#(fixture
                .primaryProjectID.uuidString)"}}}
            """#))
            let projectContent = (projectQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            #expect((projectContent?["meetings"] as? [[String: Any]])?.count == 2)

            let icalQuery = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query_meetings","arguments":{"ical_uid":"roadmap@example.com"}}}
            """#))
            let icalContent = (icalQuery["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            let icalMeetings = icalContent?["meetings"] as? [[String: Any]]
            #expect(icalMeetings?.compactMap { $0["id"] as? String } == [
                fixture.firstMeetingID.uuidString,
                fixture.recurringMeetingID.uuidString,
            ])

            let invalidProjectID = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query_meetings","arguments":{"project_id":"not-a-uuid"}}}
            """#))
            #expect((invalidProjectID["error"] as? [String: Any])?["code"] as? Int == -32602)

            let blankIcalUID = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"query_meetings","arguments":{"ical_uid":"   "}}}
            """#))
            #expect((blankIcalUID["error"] as? [String: Any])?["code"] as? Int == -32602)
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @MainActor
    struct RestrictedMCPServerTests {
        @Test
        func exposesOnlyAllowedMeetingSummaries() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let server = DahliaMCPServer(
                store: store,
                allowedMeetingIDs: [fixture.firstMeetingID]
            )

            _ = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
            #expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

            let tools = try Self.json(server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
            let definitions = ((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            #expect(definitions.map { $0["name"] as? String } == ["get_meeting"])

            let allowed = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture
                .firstMeetingID.uuidString)"}}}
            """#))
            #expect(((allowed["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["summary"] != nil)

            let deniedMeeting = try Self.json(server.handleLine(#"""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"\#(fixture
                .secondMeetingID.uuidString)"}}}
            """#))
            #expect((deniedMeeting["error"] as? [String: Any])?["code"] as? Int == -32602)

            for (id, name) in [(5, "query_meetings"), (6, "get_meeting_transcript")] {
                let deniedTool = try Self.json(server.handleLine("""
                {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"\(name)","arguments":{}}}
                """))
                #expect((deniedTool["error"] as? [String: Any])?["code"] as? Int == -32602)
            }
        }

        private static func json(_ line: String?) throws -> [String: Any] {
            let line = try #require(line)
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(value as? [String: Any])
        }
    }

    @MainActor
    final class Fixture {
        let databaseURL: URL
        let manager: AppDatabaseManager
        let primaryVaultID = UUID.v7()
        let otherVaultID = UUID.v7()
        let primaryProjectID = UUID.v7()
        let firstMeetingID = UUID.v7()
        let secondMeetingID = UUID.v7()
        let recurringMeetingID = UUID.v7()
        let otherVaultMeetingID = UUID.v7()
        let firstSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSegmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let otherVaultScreenshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let otherVaultProjectID = UUID.v7()
        let otherVaultSessionID = UUID.v7()
        var primaryMeetingIDs: Set<UUID> { [firstMeetingID, secondMeetingID, recurringMeetingID] }
        var projectMeetingIDs: Set<UUID> { [firstMeetingID, secondMeetingID] }
        var primaryScreenshotIDs: Set<UUID> { [firstScreenshotID, secondScreenshotID] }
        let imageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9WQAAAABJRU5ErkJggg=="
        )!

        init() throws {
            databaseURL = URL.temporaryDirectory
                .appending(path: "dahlia-meeting-access-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            manager = try AppDatabaseManager(path: databaseURL.path)
            let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            let sessionID = UUID.v7()

            try manager.dbQueue.write { db in
                try insertMetadata(in: db, createdAt: createdAt, projectID: primaryProjectID)
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
            try insertCalendarEvents(in: db, createdAt: createdAt)
            try insertMeetings(in: db, createdAt: createdAt, projectID: projectID)
        }

        private func insertCalendarEvents(in db: Database, createdAt: Date) throws {
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "roadmap@example.com",
                recurrenceID: "",
                title: "Roadmap review",
                startOffset: 0
            )
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "roadmap@example.com",
                recurrenceID: "20300115T000000Z",
                title: "Series follow-up",
                startOffset: 7200
            )
            try insertCalendarEvent(
                in: db,
                createdAt: createdAt,
                icalUID: "budget@example.com",
                recurrenceID: "",
                title: "Budget review",
                startOffset: 3600
            )
        }

        private func insertCalendarEvent(
            in db: Database,
            createdAt: Date,
            icalUID: String,
            recurrenceID: String,
            title: String,
            startOffset: TimeInterval
        ) throws {
            let startDate = createdAt.addingTimeInterval(startOffset)
            try CalendarEventRecord(
                now: createdAt,
                event: CalendarEvent(
                    id: "\(icalUID)-\(recurrenceID)",
                    calendarID: "work",
                    calendarName: "Work",
                    calendarColorHex: "#000000",
                    platformId: "\(icalUID)-\(recurrenceID)",
                    title: title,
                    description: "Calendar description",
                    icalUid: icalUID,
                    recurrenceId: recurrenceID,
                    startDate: startDate,
                    endDate: startDate.addingTimeInterval(3600),
                    isAllDay: false,
                    conferenceURI: nil
                ),
                key: CalendarEventKey(icalUid: icalUID, recurrenceId: recurrenceID)
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
                updatedAt: createdAt,
                calendarEventIcalUid: "budget@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
            try MeetingRecord(
                id: recurringMeetingID,
                vaultId: primaryVaultID,
                projectId: nil,
                name: "Recurring series follow-up",
                status: .ready,
                createdAt: createdAt.addingTimeInterval(5),
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: "20300115T000000Z"
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
                updatedAt: createdAt,
                calendarEventIcalUid: "roadmap@example.com",
                calendarEventRecurrenceId: ""
            ).insert(db)
        }

        private func insertContent(in db: Database, createdAt: Date, sessionID: UUID) throws {
            try SummaryRecord(
                meetingId: firstMeetingID,
                title: "AI planning title",
                document: SummaryDocument(
                    title: "AI planning title",
                    sections: [
                        SummarySection(
                            id: .v7(),
                            heading: "Summary",
                            blocks: [
                                .paragraph("Markdown secret body", transcriptRef: TranscriptReference(time: "00:00:15")),
                                .image(
                                    screenshotId: firstScreenshotID,
                                    caption: "Referenced screen",
                                    transcriptRef: TranscriptReference(time: "00:00:16")
                                ),
                            ]
                        ),
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
            try MeetingScreenshotRecord(
                id: firstScreenshotID,
                meetingId: firstMeetingID,
                sessionId: sessionID,
                capturedAt: createdAt.addingTimeInterval(6),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
            try MeetingScreenshotRecord(
                id: secondScreenshotID,
                meetingId: firstMeetingID,
                capturedAt: createdAt.addingTimeInterval(25),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
            try MeetingScreenshotRecord(
                id: otherVaultScreenshotID,
                meetingId: otherVaultMeetingID,
                sessionId: otherVaultSessionID,
                capturedAt: createdAt.addingTimeInterval(6),
                imageData: imageData,
                mimeType: "image/png"
            ).insert(db)
        }

        deinit {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        func store(vaultID: UUID) throws -> MeetingAccessStore {
            try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultID)
        }

        func updateFirstScreenshot(data: Data) throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET imageData = ? WHERE id = ?",
                    arguments: [data, firstScreenshotID]
                )
            }
        }

        func insertPausedSessionContent() throws -> (segmentID: UUID, screenshotID: UUID) {
            let sessionID = UUID.v7()
            let segmentID = UUID.v7()
            let screenshotID = UUID.v7()
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let startedAt = base.addingTimeInterval(100)
            try manager.dbQueue.write { db in
                try RecordingSessionRecord(
                    id: sessionID,
                    meetingId: firstMeetingID,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(10),
                    duration: 10,
                    offsetSeconds: 30,
                    createdAt: startedAt,
                    updatedAt: startedAt
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: segmentID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    startTime: startedAt.addingTimeInterval(5),
                    endTime: startedAt.addingTimeInterval(6),
                    text: "After pause",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: firstMeetingID,
                    sessionId: sessionID,
                    capturedAt: startedAt.addingTimeInterval(6),
                    imageData: imageData,
                    mimeType: "image/png"
                ).insert(db)
            }
            return (segmentID, screenshotID)
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

        func corruptPrimaryScreenshotSessionAssociation() throws {
            try manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET sessionId = ? WHERE id = ?",
                    arguments: [otherVaultSessionID, firstScreenshotID]
                )
            }
        }
    }
#endif
