import Foundation
import GRDB
import Synchronization
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct TranscriptAfterTests {
        @Test
        func workspaceReadsAllVaultsButCannotWidenExplicitScope() async throws {
            let fixture = try Fixture()
            let all = try DahliaMCPServer(databaseURL: fixture.databaseURL)
            let listing = try all.executeTool(named: "list_vaults", arguments: [:])
            let vaults = try #require((listing["structuredContent"] as? [String: Any])?["vaults"] as? [[String: Any]])
            #expect(vaults.count == 2)
            let result = try all.executeTool(named: "query_meetings", arguments: ["limit": 1])
            #expect(((result["structuredContent"] as? [String: Any])?["vaults"] as? [Any])?.count == 2)
            let detail = try all.executeTool(named: "get_meeting", arguments: ["meeting_id": fixture.otherVaultMeetingID.uuidString])
            #expect(detail["isError"] as? Bool == false)
            let scoped = try DahliaMCPServer(databaseURL: fixture.databaseURL, vaultID: fixture.primaryVaultID)
            #expect(throws: MeetingAccessError.vaultNotFound) {
                try scoped.executeTool(
                    named: "get_meeting",
                    arguments: ["vault_id": fixture.otherVaultID.uuidString, "meeting_id": fixture.otherVaultMeetingID.uuidString]
                )
            }
            #expect(throws: (any Error).self) { try all.executeTool(named: "query_meetings", arguments: ["cursor": "wrong"]) }
            try await fixture.manager.dbQueue.write { try $0.execute(sql: "DELETE FROM vaults") }
            let empty = try all.executeTool(named: "list_vaults", arguments: [:])
            #expect(((empty["structuredContent"] as? [String: Any])?["vaults"] as? [Any])?.isEmpty == true)
            #expect(throws: (any Error).self) { try all.executeTool(named: "query_meetings", arguments: ["unknown": "rejected"]) }

        }

        @Test
        func checkpointsPreservePaginationAndDetectChanges() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let first = try store.transcript(meetingID: fixture.firstMeetingID, limit: 1)
            let after = try #require(first.nextAfter)
            let second = try store.transcript(meetingID: fixture.firstMeetingID, limit: 1, after: after)
            let paged = try store.transcript(meetingID: fixture.firstMeetingID, limit: 1, cursor: first.nextCursor)
            #expect(second.segments == paged.segments)
            #expect(second.nextAfter == paged.nextAfter)
            let end = try #require(second.nextAfter)
            #expect(try store.transcript(meetingID: fixture.firstMeetingID, after: end).segments.isEmpty)
            #expect(try store.transcript(meetingID: fixture.firstMeetingID, after: end).nextAfter == end)
            #expect(throws: TranscriptAfterError.invalid) {
                try store.transcript(meetingID: fixture.firstMeetingID, cursor: first.nextCursor, after: after)
            }
            #expect(throws: TranscriptAfterError.invalid) {
                try store.transcript(meetingID: fixture.secondMeetingID, after: after)
            }
            #expect(throws: TranscriptAfterError.invalid) {
                try store.transcript(meetingID: fixture.firstMeetingID, fromElapsedSeconds: 10, after: after)
            }
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segment_bodies SET text = 'corrected' WHERE segmentId = ?",
                    arguments: [fixture.firstSegmentID]
                )
            }
            #expect(throws: TranscriptAfterError.changed) {
                try store.transcript(meetingID: fixture.firstMeetingID, after: end)
            }
            #expect(try store.transcript(meetingID: fixture.firstMeetingID).segments.first?.text == "corrected")
        }

        @Test
        func checkpointDetectsLateInsertionDeletionAndRegeneration() throws {
            let vault = UUID(), meeting = UUID()
            let first = entry("one"), second = entry("two")
            func page(
                _ segments: [TranscriptEntry],
                after: String? = nil,
                generation: String = "one"
            ) throws -> (segments: [TranscriptEntry], next: String) {
                try TranscriptAfter.page(
                    vaultID: vault,
                    meetingID: meeting,
                    from: nil,
                    to: nil,
                    generation: generation,
                    segments: segments,
                    after: after,
                    start: 0,
                    limit: 200
                )
            }
            let token = try page([first, second]).next
            #expect(try page([first, second, entry("three")], after: token).segments.map(\.text) == ["three"])
            for rows in [[entry("late"), first, second], [second], [first]] {
                #expect(throws: TranscriptAfterError.changed) { try page(rows, after: token) }
            }
            #expect(throws: TranscriptAfterError.changed) { try page([first, second], after: token, generation: "new") }
            let empty = try page([], generation: "none")
            #expect(try page([first], after: empty.next).segments == [first])
        }

        @Test
        func missingBodiesAreErrorsInsteadOfNoNewSpeech() throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID)
            let token = try #require(store.transcript(meetingID: fixture.firstMeetingID).nextAfter)
            try fixture.manager.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [fixture.firstSegmentID])
            }
            #expect(throws: TextContentError.incomplete) { try store.transcript(meetingID: fixture.firstMeetingID, after: token) }
        }

        @Test
        func workspaceWritesResolveIDsAndRejectCrossVaultReferences() throws {
            let fixture = try Fixture()
            let server = try DahliaMCPServer(databaseURL: fixture.databaseURL, allowsWrites: true)
            #expect(throws: (any Error).self) { try server.executeTool(named: "create_project", arguments: ["name": "ambiguous"]) }
            let created = try server.executeTool(
                named: "create_project",
                arguments: ["name": "child", "parent_project_id": fixture.otherVaultProjectID.uuidString]
            )
            #expect(created["isError"] as? Bool == false)
            let explicit = try server.executeTool(named: "create_project", arguments: ["name": "root", "vault_id": fixture.otherVaultID.uuidString])
            #expect(explicit["isError"] as? Bool == false)
            let updated = try server.executeTool(
                named: "update_project",
                arguments: ["project_id": fixture.otherVaultProjectID.uuidString, "revision": 1, "description": "updated"]
            )
            #expect(updated["isError"] as? Bool == false)
            #expect(throws: (any Error).self) {
                try server.executeTool(named: "update_project", arguments: [
                    "project_id": fixture.otherVaultProjectID.uuidString,
                    "revision": 2,
                    "parent_project_id": fixture.primaryProjectID.uuidString,
                ])
            }
            let scoped = try DahliaMCPServer(databaseURL: fixture.databaseURL, vaultID: fixture.primaryVaultID, allowsWrites: true)
            #expect(throws: (any Error).self) {
                try scoped.executeTool(named: "create_project", arguments: ["name": "outside", "vault_id": fixture.otherVaultID.uuidString])
            }
            #expect(throws: (any Error).self) {
                try scoped.executeTool(
                    named: "update_project",
                    arguments: ["project_id": fixture.otherVaultProjectID.uuidString, "revision": 2, "name": "outside"]
                )
            }
            let tools = server.workspaceToolDefinitions.compactMap { $0["name"] as? String }
            #expect(tools.contains("list_vaults"))
            #expect(!tools.contains("get_live_transcript"))
            #expect(!tools.contains("list_live_meetings"))
        }

        @Test
        func waitReturnsNewConfirmedTextWithoutHoldingTheDatabase() async throws {
            let fixture = try Fixture()
            let databaseURL = fixture.databaseURL, vaultID = fixture.primaryVaultID, meetingID = fixture.firstMeetingID
            let token = try #require(fixture.store(vaultID: vaultID).transcript(meetingID: meetingID).nextAfter)
            let ready = AsyncStream<Void>.makeStream()
            let touches = Mutex(0)
            let task = Task.detached {
                defer { ready.continuation.finish() }
                let server = try DahliaMCPServer(databaseURL: databaseURL, vaultID: vaultID, textResolver: { _, request in
                    guard request.operation == .touch else { throw TextContentError.unavailable }
                    touches.withLock { $0 += 1 }
                    ready.continuation.yield(())
                    ready.continuation.finish()
                    return Data("{}".utf8)
                })
                let response = try server.executeTool(named: "get_meeting_transcript", arguments: [
                    "meeting_id": meetingID.uuidString, "after": token, "wait": true,
                ])
                return try JSONSerialization.data(withJSONObject: response)
            }
            for await _ in ready.stream {
                break
            }
            try await fixture.manager.dbQueue.write { db in
                try TranscriptContent(
                    id: .v7(),
                    meetingId: meetingID,
                    sessionId: nil,
                    startTime: Date(timeIntervalSince1970: 1_800_001_000),
                    text: "new confirmed speech",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: nil
                ).insert(db)
            }
            let result = try #require(await JSONSerialization.jsonObject(with: task.value) as? [String: Any])
            let content = try #require(result["structuredContent"] as? [String: Any])
            #expect((content["segments"] as? [[String: Any]])?.map { $0["text"] as? String } == ["new confirmed speech"])
            #expect(content["next_after"] is String)
            #expect(touches.withLock { $0 } == 1)
        }

        @Test
        func emptyWaitTimesOutWithAReusableCheckpoint() async throws {
            let fixture = try Fixture()
            let databaseURL = fixture.databaseURL, vaultID = fixture.primaryVaultID, meetingID = fixture.firstMeetingID
            let token = try #require(fixture.store(vaultID: vaultID).transcript(meetingID: meetingID).nextAfter)
            let touches = Mutex(0)
            let result = try await Task.detached {
                let server = try DahliaMCPServer(databaseURL: databaseURL, vaultID: vaultID, textResolver: { _, request in
                    guard request.operation == .touch else { throw TextContentError.unavailable }
                    touches.withLock { $0 += 1 }
                    return Data("{}".utf8)
                })
                let result = try server.executeTool(named: "get_meeting_transcript", arguments: [
                    "meeting_id": meetingID.uuidString, "after": token, "wait": true,
                ])
                let content = result["structuredContent"] as? [String: Any]
                return (content?["segments"] as? [Any])?.isEmpty == true && content?["next_after"] as? String == token
            }.value
            #expect(result)
            #expect(touches.withLock { $0 } == 1)
        }

        private func entry(_ text: String) -> TranscriptEntry {
            TranscriptEntry(
                id: .v7(),
                text: text,
                speaker: nil,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: nil,
                elapsedSeconds: 0,
                endedElapsedSeconds: nil,
                timestamp: "00:00:00"
            )
        }
    }
#endif
