import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct LiveTranscriptTests {
        @Test
        func cursorsDetectEditsLateInsertionsAndScopeChanges() throws {
            let state = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: true)
            let first = speech("one")
            let second = speech("two")
            let page = try LiveTranscriptPage.read(state: state, generation: "1", segments: [first, second], cursor: nil, limit: 1)
            #expect(page.confirmed == [first])
            #expect(page.hasMore)
            let next = try LiveTranscriptPage.read(state: state, generation: "1", segments: [first, second], cursor: page.cursor, limit: 1)
            #expect(next.confirmed == [second])
            #expect(!next.hasMore)
            let idle = try LiveTranscriptPage.read(state: state, generation: "1", segments: [first, second], cursor: next.cursor, limit: 1)
            #expect(idle.confirmed.isEmpty)
            #expect(idle.cursor == next.cursor)
            let late = try LiveTranscriptPage.read(
                state: state,
                generation: "1",
                segments: [speech("late"), first, second],
                cursor: next.cursor,
                limit: 2
            )
            #expect(late.resetRequired)
            #expect(try LiveTranscriptPage.read(state: state, generation: "2", segments: [], cursor: next.cursor, limit: 2).resetRequired)
            let other = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: true)
            #expect(throws: LiveTranscriptError.invalidCursor) {
                try LiveTranscriptPage.read(state: other, generation: "1", segments: [], cursor: next.cursor, limit: 1)
            }
        }

        @Test
        func previewsRespectTheUTF16LimitWithoutSplittingCharacters() throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let store = LiveTranscriptStore()
            let state = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: true)
            store.begin(state, database: database)
            let cases = [
                (String(repeating: "a", count: 16001), String(repeating: "a", count: 16000)),
                (String(repeating: "😀", count: 8001), String(repeating: "😀", count: 8000)),
                ("a" + String(repeating: "😀", count: 8000), "a" + String(repeating: "😀", count: 7999)),
                (String(repeating: "e\u{301}", count: 8001), String(repeating: "e\u{301}", count: 8000)),
                (String(repeating: "👨‍👩‍👧‍👦", count: 1500), String(repeating: "👨‍👩‍👧‍👦", count: 1454)),
            ]
            for (input, expected) in cases {
                let segment = TranscriptSegment(sessionId: state.sessionId, startTime: .now, text: input, audioSource: "mic")
                store.observe(.preview(segment), meetingID: state.meetingId, database: database)
                let text = try #require(store.snapshot(meetingID: state.meetingId, database: database)?.previews.first?.text)
                #expect(text.utf16.count <= 16000)
                #expect(text == expected)
            }
        }

        @Test
        func previewsReplaceBySourceAndNeverFeedTheConfirmedStore() throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let store = LiveTranscriptStore()
            let state = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: true)
            store.begin(state, database: database)
            var mic = TranscriptSegment(sessionId: state.sessionId, startTime: .now, text: "partial", audioSource: "mic")
            let system = TranscriptSegment(sessionId: state.sessionId, startTime: .now, text: "system", audioSource: "system")
            store.observe(.preview(mic), meetingID: state.meetingId, database: database)
            store.observe(.preview(system), meetingID: state.meetingId, database: database)
            mic.text = "corrected"
            store.observe(.preview(mic), meetingID: state.meetingId, database: database)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.count == 2)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.last?.text == "corrected")
            mic.isConfirmed = true
            store.observe(.finalized(mic), meetingID: state.meetingId, database: database)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.map(\.text) == ["system"])
            store.finish(meetingID: state.meetingId, database: database)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.status == .stopped)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.isEmpty == true)
            #expect(store.list(vaultID: state.vaultId, database: database).isEmpty)
        }

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
            #expect(throws: (any Error).self) { try DahliaMCPServer(databaseURL: fixture.databaseURL, allowsWrites: true) }
            #expect(throws: (any Error).self) { try all.executeTool(named: "query_meetings", arguments: ["cursor": "wrong"]) }
            try await fixture.manager.dbQueue.write { try $0.execute(sql: "DELETE FROM vaults") }
            let empty = try all.executeTool(named: "list_vaults", arguments: [:])
            #expect(((empty["structuredContent"] as? [String: Any])?["vaults"] as? [Any])?.isEmpty == true)
            #expect(throws: (any Error).self) { try all.executeTool(named: "query_meetings", arguments: ["unknown": "rejected"]) }

        }

        @Test
        func disabledAndRestartedSessionsIgnoreOldRecognition() throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let store = LiveTranscriptStore()
            let disabled = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: false)
            store.begin(disabled, database: database)
            let old = TranscriptSegment(sessionId: disabled.sessionId, startTime: .now, text: "ignored", audioSource: "mic")
            store.observe(.preview(old), meetingID: disabled.meetingId, database: database)
            #expect(store.snapshot(meetingID: disabled.meetingId, database: database)?.previews.isEmpty == true)
            let restarted = LiveTranscriptState(
                vaultId: disabled.vaultId,
                meetingId: disabled.meetingId,
                sessionId: .v7(),
                startedAt: .now,
                enabled: true
            )
            store.begin(restarted, database: database)
            store.observe(.preview(old), meetingID: disabled.meetingId, database: database)
            #expect(store.snapshot(meetingID: disabled.meetingId, database: database)?.previews.isEmpty == true)
            let current = TranscriptSegment(sessionId: restarted.sessionId, startTime: .now, text: "current", audioSource: "mic")
            store.observe(.preview(current), meetingID: restarted.meetingId, database: database)
            store.observe(.clearPreview(sessionId: restarted.sessionId, sourceLabel: "mic"), meetingID: restarted.meetingId, database: database)
            #expect(store.snapshot(meetingID: restarted.meetingId, database: database)?.previews.isEmpty == true)
            let previous = try LiveTranscriptPage.read(state: disabled, generation: "1", segments: [], cursor: nil, limit: 1)
            #expect(try LiveTranscriptPage.read(state: restarted, generation: "1", segments: [], cursor: previous.cursor, limit: 1).resetRequired)
        }

        @Test
        func workspaceRetainsPerVaultFailuresAndValidatesLiveInputs() throws {
            let fixture = try Fixture()
            let primaryID = fixture.primaryVaultID
            let resolver: @Sendable (UUID, TextBrokerRequest) throws -> Data = { vaultID, _ in
                if vaultID == primaryID { return Data("[]".utf8) }
                throw TextContentError.authorizationRequired
            }
            let server = try DahliaMCPServer(databaseURL: fixture.databaseURL, textResolver: resolver)
            let result = try server.executeTool(named: "list_live_meetings", arguments: [:])
            let groups = try #require((result["structuredContent"] as? [String: Any])?["vaults"] as? [[String: Any]])
            #expect(groups.count == 2)
            #expect(groups.filter { $0["is_error"] as? Bool == true }.count == 1)
            #expect(groups.contains { $0["error"] as? String == "authorizationRequired" })
            let scoped = try DahliaMCPServer(databaseURL: fixture.databaseURL, vaultID: primaryID, textResolver: resolver)
            #expect(throws: LiveTranscriptError.notFound) {
                try scoped.executeTool(named: "get_live_transcript", arguments: ["meeting_id": fixture.otherVaultMeetingID.uuidString])
            }
            #expect(throws: (any Error).self) {
                try scoped.executeTool(named: "get_live_transcript", arguments: ["meeting_id": fixture.firstMeetingID.uuidString, "limit": true])
            }
        }

        @Test
        func recognizerFailurePreservesHealthySourcesAndRecoveryUntilRecordingEnds() throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let store = LiveTranscriptStore()
            let state = LiveTranscriptState(vaultId: .v7(), meetingId: .v7(), sessionId: .v7(), startedAt: .now, enabled: true)
            store.begin(state, database: database)
            let mic = TranscriptSegment(sessionId: state.sessionId, startTime: .now, text: "mic", audioSource: "mic")
            let system = TranscriptSegment(sessionId: state.sessionId, startTime: .now, text: "system", audioSource: "system")
            store.observe(.preview(mic), meetingID: state.meetingId, database: database)
            store.observe(.preview(system), meetingID: state.meetingId, database: database)
            store.observe(
                .failure(sessionId: state.sessionId, pipelineID: .v7(), sourceLabel: "mic", message: "failed"),
                meetingID: state.meetingId,
                database: database
            )
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.status == .recording)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.map(\.text) == ["system"])
            // A failed pending replacement can leave the original recognizer running.
            store.observe(.preview(mic), meetingID: state.meetingId, database: database)
            store.observe(
                .failure(sessionId: .v7(), pipelineID: .v7(), sourceLabel: "system", message: "old session"),
                meetingID: state.meetingId,
                database: database
            )
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.map(\.text) == ["system", "mic"])
            store.finish(meetingID: state.meetingId, database: database, failed: true)
            store.observe(.preview(mic), meetingID: state.meetingId, database: database)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.status == .failed)
            #expect(store.snapshot(meetingID: state.meetingId, database: database)?.previews.isEmpty == true)
        }

        @Test
        func missingConfirmedBodiesFailWithoutResettingTheCursorAndRecoverAfterRestore() async throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let vault = VaultRecord(id: .v7(), path: nil, name: "Fixture", createdAt: .now, lastOpenedAt: .now)
            try await database.write { try vault.insert($0) }
            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(), dbQueue: database, vaultId: vault.id, projectId: nil, initialName: "Fixture"
            )
            let first = TranscriptSegment(
                sessionId: service.recordingSessionId,
                startTime: .now,
                text: "first",
                isConfirmed: true,
                audioSource: "mic"
            )
            let second = TranscriptSegment(
                sessionId: service.recordingSessionId,
                startTime: .now,
                text: "second",
                isConfirmed: true,
                audioSource: "mic"
            )
            try await service.persist(.finalized(first))
            try await service.persist(.finalized(second))
            await service.stop()
            let store = LiveTranscriptStore()
            let page = try await store.read(vaultID: vault.id, meetingID: service.meetingId, cursor: nil, limit: 200, database: database)
            #expect(Set(page.confirmed.map(\.text)) == ["first", "second"])
            for segment in [second, first] {
                try await database.write { db in
                    try db.execute(sql: "DELETE FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [segment.id])
                }
                for cursor in [nil, page.cursor] {
                    await #expect(throws: TextContentError.incomplete) {
                        try await store.read(vaultID: vault.id, meetingID: service.meetingId, cursor: cursor, limit: 200, database: database)
                    }
                }
            }
            try await database.write { db in
                for segment in [first, second] {
                    try db.execute(sql: "INSERT INTO transcript_segment_bodies(segmentId, text) VALUES (?, ?)", arguments: [segment.id, segment.text])
                }
            }
            let resumed = try await store.read(vaultID: vault.id, meetingID: service.meetingId, cursor: page.cursor, limit: 200, database: database)
            #expect(resumed.confirmed.isEmpty)
            #expect(!resumed.resetRequired)
            #expect(resumed.cursor == page.cursor)
        }

        @Test
        func cloudReplacementResolvesUnassignedSpeechInsideTheLiveSessionBounds() async throws {
            let database = try AppDatabaseManager(path: ":memory:").dbQueue
            let startedAt = Date.now.addingTimeInterval(-60)
            let endedAt = startedAt.addingTimeInterval(10)
            let vault = VaultRecord(id: .v7(), path: nil, name: "Fixture", createdAt: startedAt, lastOpenedAt: startedAt)
            try await database.write { try vault.insert($0) }
            let transcriptStore = TranscriptStore()
            transcriptStore.recordingStartTime = startedAt
            let service = try await MeetingPersistenceService.createNew(
                store: transcriptStore, dbQueue: database, vaultId: vault.id, projectId: nil, initialName: "Fixture"
            )
            try await service.persist(.finalized(TranscriptSegment(
                sessionId: service.recordingSessionId,
                startTime: startedAt,
                text: "live",
                isConfirmed: true
            )))
            await service.stop()
            let store = LiveTranscriptStore()
            let state = LiveTranscriptState(
                vaultId: vault.id,
                meetingId: service.meetingId,
                sessionId: service.recordingSessionId,
                startedAt: startedAt,
                enabled: true
            )
            store.begin(state, database: database)
            store.finish(meetingID: state.meetingId, database: database)
            let live = try await store.read(vaultID: vault.id, meetingID: state.meetingId, cursor: nil, limit: 200, database: database)
            let otherSessionID = UUID.v7()
            let segments = [-1.0, 1.0, 2.0, 11.0].map { offset in
                SyncTranscriptPage.Segment(
                    segmentId: .v7(),
                    startedAt: startedAt.addingTimeInterval(offset),
                    endedAt: nil,
                    text: "cloud \(offset)",
                    createdAt: endedAt,
                    audioSource: "mic",
                    speakerLabel: nil
                )
            }
            try await database.write { db in
                var session = try #require(try RecordingSessionRecord.fetchOne(db, key: state.sessionId))
                session.endedAt = endedAt
                try session.update(db)
                session.id = otherSessionID
                session.startedAt = endedAt.addingTimeInterval(20)
                session.endedAt = endedAt.addingTimeInterval(30)
                try session.insert(db)
                try RemoteChangeApplier.applyTranscript(meetingId: state.meetingId, segments: segments, in: db)
                // An explicit foreign session must not be reassigned merely because timestamps overlap.
                try db.execute(sql: "UPDATE transcript_segments SET sessionId = ? WHERE id = ?", arguments: [otherSessionID, segments[2].segmentId])
                var run = TranscriptMetadata.Run(generatedBy: "server", startedAt: endedAt, completedAt: endedAt)
                run.audioInputs = [.init(recordingNumber: 1, source: "mic", checksum: "SHA-256:" + String(repeating: "a", count: 64))]
                try TranscriptRecord(meetingId: state.meetingId, info: .init(
                    id: .v7(),
                    startedAt: startedAt,
                    endedAt: endedAt,
                    metadata: .init(provider: "gemini", model: "gemini", runs: [run])
                ))
                .save(db)
            }
            let cloud = try await store.read(vaultID: vault.id, meetingID: state.meetingId, cursor: live.cursor, limit: 200, database: database)
            #expect(cloud.resetRequired)
            #expect(cloud.state.sessionId == state.sessionId)
            #expect(cloud.confirmed.map(\.text) == ["cloud 1.0"])
            let resumed = try await store.read(vaultID: vault.id, meetingID: state.meetingId, cursor: cloud.cursor, limit: 200, database: database)
            #expect(resumed.confirmed.isEmpty)
            #expect(!resumed.resetRequired)
        }

        private func speech(_ text: String) -> LiveSpeech {
            LiveSpeech(id: .v7(), startedAt: .now, endedAt: nil, text: text, audioSource: "mic", speakerLabel: nil)
        }
    }
#endif
