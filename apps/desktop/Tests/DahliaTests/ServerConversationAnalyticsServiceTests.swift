import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ServerConversationAnalyticsServiceTests {
        @Test
        func eligibilityRequiresOwnerCapabilityAndSynchronizedVersion() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let meetingID = UUID.v7()
            let vaultID = UUID.v7()
            let connectionID = UUID.v7()
            let origin = try #require(URL(string: "https://\(UUID().uuidString).example.test"))
            try await database.dbQueue.write { db in
                try DahliaAccountConnectionRecord(
                    id: connectionID,
                    origin: origin.absoluteString,
                    clientID: "test",
                    createdAt: .now
                ).insert(db)
                try VaultRecord(
                    id: vaultID,
                    path: nil,
                    name: "Server",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
                try MeetingRecord(
                    id: meetingID,
                    vaultId: vaultID,
                    projectId: nil,
                    name: "Meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let capability = Mutex(Data("{}".utf8))
            ImageURLProtocol.register(origin: origin.absoluteString) { request in
                #expect(request.url?.path == "/api/v1/capabilities")
                return (200, ["Content-Type": "application/json"], capability.withLock { $0 })
            }
            defer { ImageURLProtocol.remove(origin: origin.absoluteString) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerConversationAnalyticsService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test" }
            ))

            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .hidden)
            try await database.dbQueue.write { db in
                let fetched = try VaultRecord.fetchOne(db, key: vaultID)
                var vault = try #require(fetched)
                vault.accountConnectionId = connectionID
                vault.syncConfirmedConnectionId = connectionID
                vault.syncRole = "member"
                try vault.update(db)
            }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .hidden)
            try await database.dbQueue.write { db in
                let fetched = try VaultRecord.fetchOne(db, key: vaultID)
                var vault = try #require(fetched)
                vault.syncRole = "owner"
                try vault.update(db)
            }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .hidden)
            capability.withLock { $0 = Data(#"{"conversationAnalytics":{"version":1}}"#.utf8) }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .noTranscript)

            let transcriptID = UUID.v7()
            try await database.dbQueue.write { db in
                try TranscriptRecord(
                    meetingId: meetingID,
                    info: TranscriptInfo(id: transcriptID, startedAt: nil, endedAt: nil, metadata: nil)
                ).insert(db)
            }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .syncPending)
            try await database.dbQueue.write { db in
                var info = TranscriptInfo(id: transcriptID, startedAt: nil, endedAt: nil, metadata: nil)
                info.version = 3
                try TranscriptRecord(meetingId: meetingID, info: info).save(db)
            }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .syncPending)
            try await database.dbQueue.write { db in
                var info = TranscriptInfo(id: transcriptID, startedAt: nil, endedAt: .now, metadata: nil)
                info.version = 3
                try TranscriptRecord(meetingId: meetingID, info: info).save(db)
            }
            #expect(try await service.eligibility(meetingID: meetingID, dbQueue: database.dbQueue) == .available(.init(
                meetingID: meetingID,
                transcriptID: transcriptID,
                transcriptVersion: 3,
                connectionID: connectionID,
                origin: origin
            )))
        }

        @Test
        func loadRequestsExactVersionAndRejectsDifferentTranscript() async throws {
            let target = try ServerConversationAnalyticsService.Target(
                meetingID: .v7(),
                transcriptID: .v7(),
                transcriptVersion: 4,
                connectionID: .v7(),
                origin: #require(URL(string: "https://\(UUID().uuidString).example.test"))
            )
            let transcriptID = Mutex(UUID.v7())
            ImageURLProtocol.register(origin: target.origin.absoluteString) { request in
                #expect(request.url?.path == "/api/v1/meetings/\(target.meetingID.uuidString.lowercased())/transcripts/4/conversation-analytics")
                let body = """
                {"status":"unavailable","transcriptId":"\(transcriptID.withLock { $0.uuidString.lowercased() })",\
                "transcriptVersion":4,"reason":"recording_audio_missing"}
                """
                return (200, ["Content-Type": "application/json"], Data(body.utf8))
            }
            defer { ImageURLProtocol.remove(origin: target.origin.absoluteString) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerConversationAnalyticsService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test" }
            ))

            await #expect(throws: ServerConversationAnalyticsService.Failure.self) {
                try await service.load(target)
            }
            transcriptID.withLock { $0 = target.transcriptID }
            #expect(try await service.load(target) == .recordingAudioMissing)
        }
    }
#endif
