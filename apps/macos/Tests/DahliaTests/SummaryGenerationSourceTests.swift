import DahliaRuntimeSupport
#if canImport(Testing)
    import DahliaMeetingAccess
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct SummaryGenerationSourceTests {
        private static let archivedAudioJSON = """
        {"mic":{"content_type":"audio/mp4","size":1,"checksum":"SHA-256:0000000000000000000000000000000000000000000000000000000000000000",\
        "contentURL":"/audio","manifest":{"sampleRate":16000,"frameCount":16000,"ranges":[]}}}
        """

        @Test
        func localTranscriptRequiresNonWhitespaceText() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspaceID = UUID.v7(), meetingID = UUID.v7()
            try await queue.write { db in
                try WorkspaceRecord(id: workspaceID, path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now).insert(db)
                try MeetingRecord(
                    id: meetingID, workspaceId: workspaceID, projectId: nil, name: "Test", createdAt: .now, updatedAt: .now
                ).insert(db)
                try TranscriptRecord(
                    meetingId: meetingID,
                    info: TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
                ).insert(db)
                try TranscriptContent(
                    from: TranscriptSegment(startTime: .now, text: "\n\t  ", isConfirmed: true),
                    meetingId: meetingID
                ).insert(db)
            }

            var availability = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [meetingID], supportedSources: [.transcript], dbQueue: queue
            )
            #expect(availability.transcriptCount == 0)

            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segment_bodies SET text = 'Transcript' WHERE segmentId IN (SELECT id FROM transcript_segments WHERE meetingId = ?)",
                    arguments: [meetingID]
                )
            }
            availability = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [meetingID], supportedSources: [.transcript], dbQueue: queue
            )
            #expect(availability.transcriptCount == 1)
        }

        private static let documentCapabilities = Data("""
        {"documents":{"version":3},"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"],"completeRecordings":true}}
        """.utf8)

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }

    }
#endif
