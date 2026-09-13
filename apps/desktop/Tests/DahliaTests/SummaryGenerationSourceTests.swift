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
        func availabilityPrefersMigratedTranscriptAndRequiresEveryAudioArchive() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let workspaceID = UUID.v7()
            let transcriptMeetingID = UUID.v7()
            let localTranscriptMeetingID = UUID.v7()
            let audioMeetingID = UUID.v7()
            let sessionIDs = [UUID.v7(), UUID.v7()]
            try await queue.write { db in
                try WorkspaceRecord(id: workspaceID, path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now).insert(db)
                for meetingID in [transcriptMeetingID, localTranscriptMeetingID, audioMeetingID] {
                    try MeetingRecord(
                        id: meetingID,
                        workspaceId: workspaceID,
                        projectId: nil,
                        name: "Test",
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                var transcript = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
                transcript.version = 3
                try TranscriptRecord(meetingId: transcriptMeetingID, info: transcript).insert(db)
                try TranscriptContent(
                    from: TranscriptSegment(startTime: .now, text: "Migrated transcript", isConfirmed: true),
                    meetingId: transcriptMeetingID
                ).insert(db)
                try TranscriptRecord(
                    meetingId: localTranscriptMeetingID,
                    info: TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
                ).insert(db)
                try TranscriptContent(
                    from: TranscriptSegment(startTime: .now, text: "Local transcript", isConfirmed: true),
                    meetingId: localTranscriptMeetingID
                ).insert(db)

                for sessionID in sessionIDs {
                    try RecordingSessionRecord(
                        id: sessionID,
                        meetingId: audioMeetingID,
                        startedAt: .now,
                        endedAt: .now,
                        offsetSeconds: 0,
                        createdAt: .now,
                        updatedAt: .now,
                        transcriptionMode: .batch
                    ).insert(db)
                    try RecordingArchiveRecord(
                        sessionId: sessionID,
                        meetingId: audioMeetingID,
                        workspaceId: workspaceID,
                        connectionId: nil,
                        preparedJSON: sessionID == sessionIDs[0] ? #"{"mic":{}}"# : "{}",
                        state: "saved"
                    ).insert(db)
                }
            }

            let transcriptOnly = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [transcriptMeetingID],
                supportedSources: Set(SummaryGenerationSource.allCases),
                usesServer: true,
                serverTranscriptMeetingIDs: [transcriptMeetingID],
                dbQueue: queue
            )
            #expect(transcriptOnly.preferredSource == .transcript)
            #expect(transcriptOnly.audioCount == 0)

            let serverOnlyAudio = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [transcriptMeetingID],
                supportedSources: [.audio],
                usesServer: true,
                serverAudioMeetingIDs: [transcriptMeetingID],
                dbQueue: queue
            )
            #expect(serverOnlyAudio.audioCount == 1)

            let local = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [localTranscriptMeetingID],
                supportedSources: [.transcript],
                usesServer: false,
                dbQueue: queue
            )
            #expect(local.preferredSource == .transcript)
            let unsyncedServer = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [localTranscriptMeetingID],
                supportedSources: [.transcript],
                usesServer: true,
                dbQueue: queue
            )
            #expect(unsyncedServer.preferredSource == nil)

            var bulk = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [transcriptMeetingID, audioMeetingID],
                supportedSources: Set(SummaryGenerationSource.allCases),
                usesServer: true,
                serverTranscriptMeetingIDs: [transcriptMeetingID],
                dbQueue: queue
            )
            #expect(bulk.transcriptCount == 1)
            #expect(bulk.audioCount == 0)
            #expect(bulk.preferredSource == nil)

            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE recording_archives SET preparedJSON = ? WHERE sessionId = ?",
                    arguments: [#"{"system":{}}"#, sessionIDs[1]]
                )
            }
            bulk = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [transcriptMeetingID, audioMeetingID],
                supportedSources: Set(SummaryGenerationSource.allCases),
                usesServer: true,
                serverTranscriptMeetingIDs: [transcriptMeetingID],
                serverAudioMeetingIDs: [audioMeetingID],
                dbQueue: queue
            )
            #expect(bulk.transcriptCount == 1)
            #expect(bulk.audioCount == 1)
            #expect(bulk.preferredSource == nil)

            let realtimeSessionID = UUID.v7()
            try await queue.write { db in
                try RecordingSessionRecord(
                    id: realtimeSessionID,
                    meetingId: audioMeetingID,
                    startedAt: .now,
                    endedAt: .now,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now,
                    transcriptionMode: .realtime
                ).insert(db)
            }
            let serverWithRealtime = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [audioMeetingID],
                supportedSources: [.audio],
                usesServer: true,
                serverAudioMeetingIDs: [audioMeetingID],
                dbQueue: queue
            )
            #expect(serverWithRealtime.audioCount == 0)
            let localWithoutRealtime = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [audioMeetingID],
                supportedSources: [.audio],
                usesServer: false,
                dbQueue: queue
            )
            #expect(localWithoutRealtime.audioCount == 1)

            let pendingSessionID = UUID.v7()
            try await queue.write { db in
                try RecordingSessionRecord.deleteOne(db, key: realtimeSessionID)
                try RecordingSessionRecord(
                    id: pendingSessionID,
                    meetingId: audioMeetingID,
                    startedAt: .now,
                    endedAt: nil,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now,
                    transcriptionMode: .batch
                ).insert(db)
            }
            let serverWithPendingLocalAudio = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [audioMeetingID],
                supportedSources: [.audio],
                usesServer: true,
                serverAudioMeetingIDs: [audioMeetingID],
                dbQueue: queue
            )
            #expect(serverWithPendingLocalAudio.audioCount == 0)
        }

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
                meetingIDs: [meetingID], supportedSources: [.transcript], usesServer: false, dbQueue: queue
            )
            #expect(availability.transcriptCount == 0)

            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segment_bodies SET text = 'Transcript' WHERE segmentId IN (SELECT id FROM transcript_segments WHERE meetingId = ?)",
                    arguments: [meetingID]
                )
            }
            availability = try await SummaryGenerationSourceAvailability.load(
                meetingIDs: [meetingID], supportedSources: [.transcript], usesServer: false, dbQueue: queue
            )
            #expect(availability.transcriptCount == 1)
        }

        @Test(arguments: [SummaryGenerationSource.transcript, .audio])
        func serverRequestUsesSelectedSourceAndFallsBackOnlyForAnIncompatibleModel(
            source: SummaryGenerationSource
        ) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let target = ServerSummaryService.Target(
                workspaceID: .v7(),
                meetingID: .v7(),
                connectionID: .v7(),
                origin: "https://\(UUID().uuidString).example.test"
            )
            let sessionID = UUID.v7(), syncedSessionID = UUID.v7()
            let jobID = UUID.v7()
            let fileID = UUID.v7().uuidString.lowercased()
            let syncedFileID = UUID.v7().uuidString.lowercased()
            let postRequests = Mutex<[Data]>([])
            try await queue.write { db in
                try DahliaAccountConnectionRecord(
                    id: target.connectionID,
                    origin: target.origin,
                    clientID: "test",
                    createdAt: .now
                ).insert(db)
                let workspace = WorkspaceRecord(
                    id: target.workspaceID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now,
                    accountConnectionId: target.connectionID, organizationId: .v7(), syncRole: "admin",
                    syncConfirmedConnectionId: target.connectionID, syncPullCursor: "ready"
                )
                try workspace.insert(db)
                try MeetingRecord(
                    id: target.meetingID, workspaceId: target.workspaceID, projectId: nil,
                    name: "Test", createdAt: .now, updatedAt: .now
                ).insert(db)
                var transcript = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
                transcript.version = 4
                try TranscriptRecord(meetingId: target.meetingID, info: transcript).insert(db)
                try TranscriptContent(
                    from: TranscriptSegment(startTime: .now, text: "Transcript", isConfirmed: true),
                    meetingId: target.meetingID
                ).insert(db)
                try RecordingSessionRecord(
                    id: sessionID,
                    meetingId: target.meetingID,
                    startedAt: .now,
                    endedAt: .now,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now,
                    transcriptionMode: .batch
                ).insert(db)
                try RecordingArchiveRecord(
                    sessionId: sessionID, meetingId: target.meetingID, workspaceId: target.workspaceID,
                    connectionId: target.connectionID, number: 1, audioJSON: Self.archivedAudioJSON, state: "remote"
                ).insert(db)
            }
            let settings = ServerAccountSettings(
                processing: .init(location: .remote, remote: .init(
                    workflow: .transcribeThenSummarize,
                    summaryModel: "gpt-text",
                    reasoningEffort: "high"
                )),
                summary: .init(style: .detailed),
                outputLanguage: .ja,
                analysisLanguages: .init(scope: .all, identifiers: [])
            )
            ImageURLProtocol.register(origin: target.origin) { request in
                let path = request.url!.path
                if path == "/api/v1/capabilities" {
                    return (
                        200,
                        [:],
                        Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"],"completeRecordings":true}}"#.utf8)
                    )
                }
                if path == "/api/v1/models" {
                    return (200, [:], Data("""
                    {"data":[{"id":"gpt-text"}],"models":[{"slug":"gpt-text","display_name":"GPT","supported_reasoning_levels":[],
                    "default_reasoning_level":null,"input_modalities":["text"],"summary_methods":["transcript"]}]}
                    """.utf8))
                }
                if path.hasSuffix("/transcripts/latest") {
                    return (200, [:], Data("""
                    {"formatVersion":1,"version":5,"entityId":"\(target.meetingID.uuidString.lowercased())","present":true,
                    "count":1,"byteCount":10,"sha256":"test","entity":"transcript","syncRevision":5,
                    "items":[{"segmentId":"\(target.meetingID.uuidString.lowercased())","startedAt":"2026-09-09T00:00:00Z","endedAt":null,
                    "text":"Server transcript","createdAt":null,"audioSource":null,"speakerLabel":null}],"nextCursor":null}
                    """.utf8))
                }
                if path.hasSuffix("/recordings") {
                    return (200, [:], Data("""
                    {"items":[{"id":1,"startedAt":"2026-09-09T00:00:00Z","endedAt":"2026-09-09T00:00:01Z","audio":{"mic":{
                    "fileId":"\(fileID)","contentType":"audio/mp4","size":1,"checksum":null,"contentUrl":"/audio"}}},
                    {"id":2,"startedAt":"2026-09-09T00:00:02Z","endedAt":"2026-09-09T00:00:03Z","audio":{"mic":{
                    "fileId":"\(syncedFileID)","contentType":"audio/mp4","size":1,"checksum":null,"contentUrl":"/audio"}}}],"nextCursor":null}
                    """.utf8))
                }
                if request.httpMethod == "POST" {
                    if let body = request.httpBody ?? request.httpBodyStream.map(Self.read) {
                        postRequests.withLock { $0.append(body) }
                    }
                    return (202, ["Content-Type": "application/json"], Data("""
                    {"job":{"id":"\(jobID.uuidString.lowercased())","method":"\(source
                        .rawValue)","settings":{"model":"gpt-text","detail":"high","reasoningEffort":"high"},
                    "outputLanguage":"ja","attempts":1,"createdAt":"2026-09-09T00:00:00.000Z","updatedAt":"2026-09-09T00:00:00.000Z",
                    "status":"succeeded","error":null,"stage":"saving"}}
                    """.utf8))
                }
                return (
                    404,
                    ["Content-Type": "application/problem+json"],
                    Data(#"{"type":"about:blank","title":"Not found","status":404,"code":"summary_job_not_found"}"#.utf8)
                )
            }
            defer { ImageURLProtocol.remove(origin: target.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let prepared = Mutex<ServerSummaryService.Request?>(nil)
            let service = ServerSummaryService(
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }),
                synchronize: { _, queue in
                    guard source == .audio else { return }
                    try await queue.write { db in
                        try RecordingSessionRecord(
                            id: syncedSessionID,
                            meetingId: target.meetingID,
                            startedAt: Date(timeIntervalSince1970: 2),
                            endedAt: Date(timeIntervalSince1970: 3),
                            offsetSeconds: 2,
                            createdAt: .now,
                            updatedAt: .now,
                            transcriptionMode: .batch
                        ).save(db)
                        try RecordingArchiveRecord(
                            sessionId: syncedSessionID,
                            meetingId: target.meetingID,
                            workspaceId: target.workspaceID,
                            connectionId: target.connectionID,
                            number: 2,
                            audioJSON: Self.archivedAudioJSON,
                            state: "remote"
                        ).save(db)
                    }
                }
            )

            try await service.generate(
                target,
                id: jobID,
                detail: nil,
                dbQueue: queue,
                source: source,
                accountSettings: settings,
                onPrepared: { request in prepared.withLock { $0 = request } }
            )

            let request = try #require(prepared.withLock { $0 })
            assertPreparedRequest(request, source: source, fileIDs: [fileID, syncedFileID])

            try await assertPreparedRequestIsReused(
                request, service: service, target: target, queue: queue, settings: settings,
                source: source, jobID: jobID, postRequests: postRequests
            )

            try await assertUnavailableManualModelPreserved(
                service: service, target: target, queue: queue, settings: settings, source: source, jobID: jobID
            )

            if source == .audio {
                try await assertPendingAudioFailsBeforeStarting(
                    target: target, queue: queue, settings: settings, postRequests: postRequests
                )
            }
        }

        private func assertPreparedRequest(
            _ request: ServerSummaryService.Request,
            source: SummaryGenerationSource,
            fileIDs: Set<String>
        ) {
            switch source {
            case .transcript:
                #expect(request.input.type == "transcript")
                #expect(request.input.version == "5")
                #expect(request.preferences?.processing.remote.workflow == .transcribeThenSummarize)
                #expect(request.preferences?.processing.remote.summaryModel == "gpt-text")
                #expect(request.preferences?.processing.remote.reasoningEffort == "high")
            case .audio:
                #expect(request.input.type == "recording")
                #expect(Set(request.input.recordings?.compactMap(\.micFileId) ?? []) == fileIDs)
                #expect(request.preferences?.processing.remote.workflow == .combined)
                #expect(request.preferences?.processing.remote.summaryModel == nil)
                #expect(request.preferences?.processing.remote.reasoningEffort == nil)
            }
        }

        private func assertPreparedRequestIsReused(
            _ request: ServerSummaryService.Request,
            service: ServerSummaryService,
            target: ServerSummaryService.Target,
            queue: DatabaseQueue,
            settings: ServerAccountSettings,
            source: SummaryGenerationSource,
            jobID: UUID,
            postRequests: borrowing Mutex<[Data]>
        ) async throws {
            try await service.generate(
                target, id: jobID, detail: nil, dbQueue: queue, source: source,
                preparedRequest: request, accountSettings: settings
            )
            let posts = postRequests.withLock { $0 }
            #expect(posts.count == 2)
            #expect(posts.first == posts.last)
        }

        private func assertPendingAudioFailsBeforeStarting(
            target: ServerSummaryService.Target,
            queue: DatabaseQueue,
            settings: ServerAccountSettings,
            postRequests: borrowing Mutex<[Data]>
        ) async throws {
            let pendingSessionID = UUID.v7()
            let requestsBeforePendingAudio = postRequests.withLock { $0.count }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }),
                synchronize: { _, queue in
                    try await queue.write { db in
                        try RecordingSessionRecord(
                            id: pendingSessionID,
                            meetingId: target.meetingID,
                            startedAt: .now,
                            endedAt: nil,
                            offsetSeconds: 0,
                            createdAt: .now,
                            updatedAt: .now,
                            transcriptionMode: .batch
                        ).save(db)
                    }
                }
            )
            do {
                try await service.generate(
                    target, id: .v7(), detail: nil, dbQueue: queue, source: .audio, accountSettings: settings
                )
                Issue.record("Manual audio generation should fail while a synchronized recording is pending")
            } catch ServerSummaryService.Failure.syncPending {
                #expect(postRequests.withLock { $0.count } == requestsBeforePendingAudio)
            }
        }

        private func assertUnavailableManualModelPreserved(
            service: ServerSummaryService,
            target: ServerSummaryService.Target,
            queue: DatabaseQueue,
            settings: ServerAccountSettings,
            source: SummaryGenerationSource,
            jobID: UUID
        ) async throws {
            var settings = settings
            var processing = try #require(settings.processing)
            processing.remote.summaryModel = "missing-model"
            settings.processing = processing
            let prepared = Mutex<ServerSummaryService.Request?>(nil)
            try await service.generate(
                target, id: jobID, detail: nil, dbQueue: queue, source: source, accountSettings: settings,
                onPrepared: { request in prepared.withLock { $0 = request } }
            )
            let request = try #require(prepared.withLock { $0 })
            #expect(request.preferences?.processing.remote.summaryModel == "missing-model")
            #expect(request.preferences?.processing.remote.reasoningEffort == "high")
        }

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

        @MainActor
        @Test
        func serverAvailabilityUsesLiveCapabilitiesAndCanonicalTranscriptUnlessItsMutationIsPending() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let target = ServerSummaryService.Target(
                workspaceID: .v7(), meetingID: .v7(), connectionID: .v7(),
                origin: "https://\(UUID.v7().uuidString.lowercased()).example.test"
            )
            try await queue.write { db in
                try DahliaAccountConnectionRecord(
                    id: target.connectionID, origin: target.origin, clientID: "test", createdAt: .now
                ).insert(db)
                let workspace = WorkspaceRecord(
                    id: target.workspaceID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now,
                    accountConnectionId: target.connectionID, organizationId: .v7(), syncRole: "admin",
                    syncConfirmedConnectionId: target.connectionID, syncPullCursor: "ready"
                )
                try workspace.insert(db)
                try MeetingRecord(
                    id: target.meetingID, workspaceId: target.workspaceID, projectId: nil, name: "Test",
                    createdAt: .now, updatedAt: .now
                ).insert(db)
                var info = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: .now, metadata: nil)
                info.version = 2
                try TranscriptRecord(meetingId: target.meetingID, info: info).insert(db)
            }
            let capabilityRequests = Mutex(0)
            let transcriptRequests = Mutex(0)
            let recordingRequests = Mutex(0)
            let audioOnly = Mutex(false)
            ImageURLProtocol.register(origin: target.origin) { request in
                if request.url!.path == "/api/v1/capabilities" {
                    let requestNumber = capabilityRequests.withLock {
                        $0 += 1
                        return $0
                    }
                    if requestNumber == 1 { return (503, [:], Data()) }
                    let sources = audioOnly.withLock { $0 } ? #"["audio"]"# : #"["transcript","audio"]"#
                    return (200, [:], Data("""
                    {"meetingSummaryGeneration":{"version":2,"sources":\(sources),"completeRecordings":true}}
                    """.utf8))
                }
                if request.url!.path.hasSuffix("/recordings") {
                    #expect(request.value(forHTTPHeaderField: "X-Dahlia-Require-Complete-Recordings") == "1")
                    let requestNumber = recordingRequests.withLock {
                        $0 += 1
                        return $0
                    }
                    if requestNumber != 2 { return (500, [:], Data()) }
                    return (409, [:], Data())
                }
                let requestNumber = transcriptRequests.withLock {
                    $0 += 1
                    return $0
                }
                let secondPage = requestNumber == 2
                #expect(request.url!.path.hasSuffix(secondPage ? "/transcripts/7" : "/transcripts/latest"))
                let text = secondPage ? "Server only transcript" : "   "
                let cursor = secondPage ? "null" : #""2026-09-09T00:00:00.000Z,\#(target.meetingID.uuidString.lowercased())""#
                return (200, [:], Data("""
                {"formatVersion":1,"version":7,"entityId":"\(target.meetingID.uuidString.lowercased())","present":true,
                "count":2,"byteCount":20,"sha256":"test","entity":"transcript","syncRevision":7,
                "items":[{"segmentId":"\(target.meetingID.uuidString.lowercased())","startedAt":"2026-09-09T00:00:00Z","endedAt":null,
                "text":"\(text)","createdAt":null,"audioSource":null,"speakerLabel":null}],"nextCursor":\(cursor)}
                """.utf8))
            }
            defer { ImageURLProtocol.remove(origin: target.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }
            ))
            let viewModel = CaptionViewModel(
                summaryAccountSettingsLoader: { _ in
                    ServerAccountSettings(
                        processing: .init(location: .remote), summary: .init(style: .standard),
                        outputLanguage: .ja, analysisLanguages: .init(scope: .all, identifiers: [])
                    )
                },
                serverSummaryService: service
            )

            await #expect(throws: (any Error).self) {
                try await viewModel.summaryGenerationSourceAvailability(
                    meetingIDs: [target.meetingID], dbQueue: queue
                )
            }
            var availability = try await viewModel.summaryGenerationSourceAvailability(
                meetingIDs: [target.meetingID], dbQueue: queue
            )
            #expect(availability.preferredSource == .transcript)
            #expect(capabilityRequests.withLock { $0 } == 2)
            #expect(transcriptRequests.withLock { $0 } == 2)
            #expect(recordingRequests.withLock { $0 } == 1)

            try await queue.write { db in
                let current = try TranscriptRecord.current(target.meetingID, in: db)
                let info = try #require(current)
                try SyncTransactionRecorder.record(
                    workspaceId: target.workspaceID,
                    operations: [TranscriptRecord.mutation(meetingId: target.meetingID, info: info, mode: "append")],
                    in: db
                )
            }
            availability = try await viewModel.summaryGenerationSourceAvailability(
                meetingIDs: [target.meetingID], dbQueue: queue
            )
            #expect(availability.preferredSource == nil)
            #expect(capabilityRequests.withLock { $0 } == 3)
            #expect(transcriptRequests.withLock { $0 } == 2)
            #expect(recordingRequests.withLock { $0 } == 2)

            audioOnly.withLock { $0 = true }
            await #expect(throws: (any Error).self) {
                try await viewModel.summaryGenerationSourceAvailability(
                    meetingIDs: [target.meetingID], dbQueue: queue
                )
            }
        }
    }
#endif
