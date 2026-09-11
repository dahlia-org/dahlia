import DahliaRuntimeSupport
#if canImport(Testing)
    import DahliaServerAPI
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct ServerSummaryServiceTests {
        @Test
        func recordingJobResponsesRemainReadableAcrossActionsAndRecovery() async throws {
            let target = ServerSummaryService.Target(
                vaultID: .v7(), meetingID: .v7(), connectionID: .v7(),
                origin: "https://\(UUID().uuidString).example.test"
            )
            let id = UUID.v7()
            let body = ServerSummaryService.Request(
                id: id.uuidString.lowercased(),
                input: .init(type: "recording", recordings: (0 ..< 74).map { _ in
                    .init(micFileId: UUID.v7().uuidString.lowercased(), systemFileId: UUID.v7().uuidString.lowercased())
                }),
                model: "gemini-3-8-flash", detailLevel: "high", summaryLanguage: "ja"
            )
            let encoded = try JSONEncoder().encode(body)
            #expect(encoded.count <= 8192)
            var job = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            job["method"] = "audio"
            job["outputLanguage"] = "ja"
            job["attempts"] = 1
            job["error"] = NSNull()
            job["status"] = "processing"
            job["stage"] = "transcribing"
            job["createdAt"] = "2026-09-09T00:00:00.000Z"
            job["updatedAt"] = "2026-09-09T00:00:00.000Z"
            job["settings"] = ["model": "gemini-3-8-flash", "detail": "high", "reasoningEffort": "medium"]
            let response = try JSONSerialization.data(withJSONObject: ["job": job])
            #expect(response.count > 8192)
            ImageURLProtocol.register(origin: target.origin) { request in
                (
                    request.httpMethod == "POST" && !request.url!.path.hasSuffix("/cancel") ? 202 : 200,
                    ["Content-Type": "application/json"],
                    response
                )
            }
            defer { ImageURLProtocol.remove(origin: target.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }
            ))
            #expect(try await service.start(target, request: body)?.id == body.id)
            #expect(try await service.status(target)?.id == body.id)
            #expect(try await service.status(target, id: id)?.id == body.id)
            #expect(try await service.cancel(target, id: id)?.id == body.id)
            #expect(try await service.retry(target, previousID: body.id, id: .v7())?.id == body.id)
        }

        @Test(arguments: [false, true])
        func generationPreparesSynchronizationBeforeAnyJobRequest(detached: Bool) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let target = ServerSummaryService.Target(
                vaultID: .v7(),
                meetingID: .v7(),
                connectionID: .v7(),
                origin: "https://\(UUID().uuidString).example.test"
            )
            try await queue.write { db in
                try DahliaAccountConnectionRecord(id: target.connectionID, origin: target.origin, clientID: "test", createdAt: .now).insert(db)
                var vault = VaultRecord(id: target.vaultID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
                vault.accountConnectionId = detached ? nil : target.connectionID
                vault.syncConfirmedConnectionId = target.connectionID
                vault.syncPullCursor = "before"
                try vault.insert(db)
                try MeetingRecord(id: target.meetingID, vaultId: target.vaultID, projectId: nil, name: "New", createdAt: .now, updatedAt: .now)
                    .insert(db)
            }
            let paths = Mutex<[String]>([])
            ImageURLProtocol.register(origin: target.origin) { request in
                let path = request.url!.path
                paths.withLock { $0.append(path) }
                if path == "/api/v1/capabilities" { return (
                    200,
                    [:],
                    Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript"]}}"#.utf8)
                )
                }
                // Synchronization is unavailable; the unsynchronized meeting's job API must never be queried.
                return (404, [:], Data(#"{"error":"summary_meeting_unavailable"}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: target.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test" }
            ))
            await #expect(throws: (any Error).self) {
                try await service.generate(target, id: .v7(), detail: nil, dbQueue: queue)
            }
            let requested = paths.withLock { $0 }
            #expect(!requested.contains { $0.hasSuffix("/summaries") || $0.hasSuffix("/summary-jobs/latest") })
            #expect(requested.count == (detached ? 1 : 2))
        }

        @Test(arguments: [1, 2], [false, true])
        func generationRetriesPullContentionBeforeAndAfterTheJob(contendedCall: Int, transientFailure: Bool) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let target = ServerSummaryService.Target(
                vaultID: .v7(),
                meetingID: .v7(),
                connectionID: .v7(),
                origin: "https://\(UUID().uuidString).example.test"
            )
            let id = UUID.v7()
            try await queue.write { db in
                try DahliaAccountConnectionRecord(id: target.connectionID, origin: target.origin, clientID: "test", createdAt: .now).insert(db)
                var vault = VaultRecord(id: target.vaultID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
                vault.accountConnectionId = target.connectionID
                vault.syncConfirmedConnectionId = target.connectionID
                vault.syncPullCursor = "before"
                try vault.insert(db)
                try MeetingRecord(id: target.meetingID, vaultId: target.vaultID, projectId: nil, name: "New", createdAt: .now, updatedAt: .now)
                    .insert(db)
                var info = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: nil, metadata: nil)
                info.version = 1
                try TranscriptRecord(meetingId: target.meetingID, info: info).insert(db)
            }
            let posts = Mutex<[Data]>([])
            let legacySettings = try JSONDecoder().decode(ServerAccountSettings.self, from: Data("""
            {"summary":{"method":"transcript","detail":"high","methodSettings":{"transcript":{"model":"gpt-5.4","reasoningEffort":"medium"}}},
             "outputLanguage":"ja","analysisLanguages":{"scope":"all","identifiers":[]}}
            """.utf8))
            var processing = RecordingProcessing(
                id: id,
                automatic: true,
                liveDraft: false,
                localeIdentifier: "ja_JP",
                method: .transcript,
                options: .init(exportOptions: .manual, detailLevel: .detailed),
                generationSettings: .init(
                    modelID: "gpt-5.4",
                    reasoningEffort: "medium",
                    detailLevelInstruction: "detail",
                    languageDisplayName: "Japanese",
                    runtimeProvider: .chatGPTSubscription
                ),
                serverSettings: legacySettings
            )
            processing.serverRequest = .init(
                id: id.uuidString.lowercased(), input: .init(type: "transcript", version: "1"),
                model: "gpt-5.4", detailLevel: "high", summaryLanguage: "ja"
            )
            ImageURLProtocol.register(origin: target.origin) { request in
                if request.url!.path == "/api/v1/capabilities" { return (
                    200,
                    [:],
                    Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript"]}}"#.utf8)
                )
                }
                if request.url!.path == "/api/v1/account/settings" {
                    return (200, [:], Data("""
                    {"settings":{"summary":{"style":"detailed"},"processing":{"location":"remote","remote":{"workflow":"transcribeThenSummarize"}},
                    "outputLanguage":"ja","analysisLanguages":{"scope":"all","identifiers":[]}}}
                    """.utf8))
                }
                if request.httpMethod == "POST", let body = request.httpBody ?? request.httpBodyStream.map(Self.read) {
                    posts.withLock { $0.append(body) }
                } else if posts.withLock({ $0 }).isEmpty { return (
                    404,
                    ["Content-Type": "application/problem+json"],
                    Data(#"{"type":"about:blank","title":"Not found","status":404,"code":"summary_job_not_found"}"#.utf8)
                )
                }
                return (
                    request.httpMethod == "POST" ? 202 : 200,
                    ["Content-Type": "application/json"],
                    Data(
                        "{\"job\":{\"method\":\"transcript\",\"settings\":{\"model\":\"gpt-5.4\",\"detail\":\"high\",\"reasoningEffort\":\"medium\"},\"outputLanguage\":\"ja\",\"attempts\":1,\"createdAt\":\"2026-09-09T00:00:00.000Z\",\"error\":null,\"id\":\"\(id.uuidString)\",\"status\":\"succeeded\"}}"
                            .utf8
                    )
                )
            }
            defer { ImageURLProtocol.remove(origin: target.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let pulls = Mutex(0)
            let service = ServerSummaryService(
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }),
                synchronize: { _, _ in
                    let call = pulls.withLock { $0 += 1
                        return $0
                    }
                    if call == contendedCall {
                        if transientFailure { throw URLError(.networkConnectionLost) }
                        throw TextContentError.changed
                    }
                }
            )
            if transientFailure {
                await #expect(throws: URLError.self) {
                    try await service.generate(target, id: id, detail: nil, dbQueue: queue, processing: processing)
                }
            }
            try await service.generate(target, id: id, detail: nil, dbQueue: queue, processing: processing)
            #expect(pulls.withLock { $0 } == (transientFailure && contendedCall == 2 ? 4 : 3))
            let body = try JSONDecoder().decode(
                Operations.StartSummaryJob.Input.Body.JsonPayload.Value1Payload.self,
                from: #require(posts.withLock { $0.first })
            )
            #expect(body.reasoningEffort?.rawValue == "medium")
            #expect(posts.withLock { $0.count } == 1)
        }

        @Test(arguments: [String?.none, "low"])
        func sendsOnlyIdAndDetailAndReadsDurableState(detail: String?) async throws {
            let origin = "https://\(UUID().uuidString).example.test"
            let id = UUID.v7()
            let target = ServerSummaryService.Target(vaultID: .v7(), meetingID: .v7(), connectionID: .v7(), origin: origin)
            let posts = Mutex<[Data]>([])
            ImageURLProtocol.register(origin: origin) { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                if request.url?.path == "/api/v1/capabilities" {
                    return (200, [:], Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript"]}}"#.utf8))
                }
                #expect(request.url?
                    .path ==
                    "/api/v1/meetings/\(target.meetingID.uuidString.lowercased())/summary-jobs" +
                    (request.httpMethod == "POST" ? "" : "/latest"))
                if request.httpMethod == "POST", let body = request.httpBody ?? request.httpBodyStream.map(Self.read) {
                    posts.withLock { $0.append(body) }
                }
                return (
                    request.httpMethod == "POST" ? 202 : 200,
                    ["Content-Type": "application/json"],
                    Data(
                        "{\"job\":{\"method\":\"transcript\",\"settings\":{\"model\":\"gpt-5.4\",\"detail\":\"high\",\"reasoningEffort\":\"medium\"},\"outputLanguage\":\"ja\",\"attempts\":1,\"createdAt\":\"2026-09-09T00:00:00.000Z\",\"error\":null,\"id\":\"\(id.uuidString.lowercased())\",\"status\":\"processing\",\"error\":null}}"
                            .utf8
                    )
                )
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test-token" }
            ))
            #expect(try await service.methods(connectionID: target.connectionID, origin: origin) == ["transcript"])
            #expect(try await service.start(target, id: id, detail: detail)?.isActive == true)
            #expect(try await service.start(target, id: id, detail: detail)?.id == id.uuidString.lowercased())
            #expect(try await service.status(target)?.isActive == true)
            let sent = posts.withLock { $0 }
            #expect(sent.count == 2)
            for data in sent {
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
                var expected = ["id": id.uuidString.lowercased()]
                if let detail { expected["detail"] = detail }
                #expect(body == expected)
            }
        }

        @Test
        func modelPickerUsesOnlyListedGatewayModelsAndTheirEfforts() async throws {
            let origin = "https://\(UUID().uuidString).example.test"
            ImageURLProtocol.register(origin: origin) { request in
                #expect(request.url?.path == "/api/v1/models")
                return (
                    200,
                    [:],
                    Data(
                        """
                        {"data":[{"id":"available"},{"id":"unsupported"},{"id":"codex-auto-review"}],"models":[
                          {"slug":"available","display_name":"Available",
                           "supported_reasoning_levels":[{"effort":"max"}],"default_reasoning_level":"max","supports_json_schema":true},
                          {"slug":"unsupported","display_name":"Unsupported","supported_reasoning_levels":[],"default_reasoning_level":null},
                          {"slug":"codex-auto-review","display_name":"Codex Auto Review",
                           "supported_reasoning_levels":[{"effort":"medium"}],"default_reasoning_level":"medium"},
                          {"slug":"hidden","display_name":"Hidden","supported_reasoning_levels":[],"default_reasoning_level":null}
                        ]}
                        """
                        .utf8
                    )
                )
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test" }
            ))
            let models = try await service.models(connectionID: .v7(), origin: origin)
            #expect(models.map(\.id) == ["available", "unsupported"])
            #expect(models.filter { $0.supportsSummary(method: "transcript") }.map(\.id) == ["available", "unsupported"])
            #expect(models.first?.supportedReasoningLevels.map(\.effort) == ["max"])
            #expect(models.first?.defaultReasoningLevel == "max")
            #expect(models.first?.supportsSummary(method: "transcript") == true)
            #expect(ServerSummaryService.Failure.generationFailed("summary_input_changed").errorDescription == L10n.serverSummaryInputChanged)
        }

        @Test
        func decodesAccountMethodSettingsWithoutChangingLanguagePatch() throws {
            let body = Data(
                """
                {"settings":{"outputLanguage":"ja","analysisLanguages":{"scope":"all","identifiers":[]},
                "summary":{"method":"transcript","detail":"detailed","methodSettings":{"transcript":{"model":"catalog.ai.model","reasoningEffort":"high"}}}}}
                """.utf8
            )
            let response = try JSONDecoder().decode(ServerAccountSettings.Response.self, from: body)
            #expect(response.settings?.processing?.remote.summaryModel == "catalog.ai.model")
            #expect(response.settings?.processing?.location == .local)
            let patch = try JSONEncoder().encode(ServerAccountSettings.Patch(outputLanguage: .en))
            let json = try #require(JSONSerialization.jsonObject(with: patch) as? [String: String])
            #expect(json == ["outputLanguage": "en"])
        }

        @Test
        func summaryDetailIsIndependentOfMethod() throws {
            let body = Data(
                """
                {"outputLanguage":"ja","analysisLanguages":{"scope":"all","identifiers":[]},"summary":{"method":"audio","detail":"standard","methodSettings":{
                  "transcript":{"model":"gpt-5.4","reasoningEffort":"high"},
                  "audio":{"model":"gemini-3-8-flash","reasoningEffort":"medium"}
                }}}
                """.utf8
            )
            var settings = try JSONDecoder().decode(ServerAccountSettings.self, from: body)
            #expect(settings.processing?.remote.summaryModel == "gemini-3-8-flash")
            #expect(settings.processing?.remote.reasoningEffort == "medium")
            #expect(settings.processing?.location == .remote)
            #expect(settings.summary?.detailLevel == .standard)
            settings.processing?.location = .local
            #expect(settings.summary?.detailLevel == .standard)
        }

        @Test
        func summaryModelChoicesRespectServerMethods() throws {
            for (id, methods, transcript, audio) in [
                ("gpt-4.1", ["transcript"], true, false),
                ("gemini-3-flash", ["audio"], false, true),
                ("gpt-5.6-luna", [], false, false),
            ] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "slug": id, "display_name": id, "supported_reasoning_levels": [],
                    "input_modalities": ["text", "image", "audio"], "supports_json_schema": true,
                    "summary_methods": methods,
                ])
                let model = try JSONDecoder().decode(ServerSummaryService.Model.self, from: data)
                #expect(model.supportsSummary(method: "transcript") == transcript)
                #expect(model.supportsSummary(method: "cloudTranscription") == transcript)
                #expect(model.supportsSummary(method: "audio") == audio)
            }
        }

        @Test(arguments: [
            ("gemini-3-8-flash", ["text", "image", "audio"], true),
            ("gemini-3-7-flash", ["audio"], true),
            ("gemini-text-only", ["text"], false),
            ("other-audio", ["audio"], false),
        ])
        func audioModelChoicesRequireGeminiAndAudioInput(id: String, inputs: [String], expected: Bool) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "slug": id, "display_name": id, "supported_reasoning_levels": [], "input_modalities": inputs, "supports_json_schema": true,
            ])
            let model = try JSONDecoder().decode(ServerSummaryService.Model.self, from: data)
            #expect(model.supportsAudioSummary == expected)
        }

        @Test(arguments: [false, nil] as [Bool?])
        func listedAudioModelDoesNotRequireLegacySchemaFlag(support: Bool?) throws {
            var json: [String: Any] = [
                "slug": "gemini-audio", "display_name": "Gemini", "supported_reasoning_levels": [], "input_modalities": ["audio"],
            ]
            if let support { json["supports_json_schema"] = support }
            let model = try JSONDecoder().decode(ServerSummaryService.Model.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(model.supportsAudioSummary)
        }

        @Test(arguments: [
            "{}",
            #"{"meetingSummaryGeneration":{"version":3,"sources":["transcript","audio"]}}"#,
            #"{"meetingSummaryGeneration":{"version":2,"sources":[]}}"#,
        ])
        func missingOrUnsupportedCapabilitiesHaveNoMethods(_ json: String) async throws {
            let origin = "https://capabilities-\(UUID.v7().uuidString.lowercased()).test"
            ImageURLProtocol.register(origin: origin) { request in
                #expect(request.url?.path == "/api/v1/capabilities")
                return (200, [:], Data(json.utf8))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }
            ))
            #expect(try await service.methods(connectionID: .v7(), origin: origin).isEmpty)
        }

        @Test
        func legacyCapabilityKeepsAutomaticAudioButNotManualAudio() async throws {
            let origin = "https://capabilities-\(UUID.v7().uuidString.lowercased()).test"
            ImageURLProtocol.register(origin: origin) { _ in
                (200, [:], Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"]}}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let service = ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }
            ))

            #expect(try await service.methods(connectionID: .v7(), origin: origin) == ["transcript", "audio"])
            #expect(try await service.manualMethods(connectionID: .v7(), origin: origin) == ["transcript"])
        }

        @Test
        func encodesAccountStylePatch() throws {
            let patch = ServerAccountSettings.Patch(summary: .init(style: .concise))
            let data = try JSONEncoder().encode(patch)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
            #expect(json == ["summary": ["style": "concise"]])
            let response = try JSONDecoder().decode(ServerAccountSettings.Response.self, from: Data(#"{"settings":null}"#.utf8))
            #expect(response.settings == nil)
        }

        @Test(arguments: ["succeeded", "failed", "cancelled"])
        func cloudProcessingKeepsItsCapturedRecordingAndMarksOnlyThatSessionComplete(status: String) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let target = ServerSummaryService.Target(
                vaultID: .v7(),
                meetingID: .v7(),
                connectionID: .v7(),
                origin: "https://\(UUID().uuidString).example.test"
            )
            let first = UUID.v7(), later = UUID.v7(), jobID = UUID.v7(), fileID = UUID.v7()
            let audioJSON = try String(decoding: SyncJSON.encoder.encode([
                "mic": RecordingArchivedAudio(
                    contentType: "audio/mp4",
                    size: 1,
                    checksum: "SHA-256:" + String(repeating: "0", count: 64),
                    contentURL: "/audio",
                    manifest: .init(sampleRate: 16000, frameCount: 16000, ranges: [])
                ),
            ]), as: UTF8.self)
            try await queue.write { db in
                try DahliaAccountConnectionRecord(id: target.connectionID, origin: target.origin, clientID: "test", createdAt: .now).insert(db)
                var vault = VaultRecord(id: target.vaultID, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
                vault.accountConnectionId = target.connectionID
                vault.syncConfirmedConnectionId = target.connectionID
                vault.syncPullCursor = "ready"
                try vault.insert(db)
                try MeetingRecord(id: target.meetingID, vaultId: target.vaultID, projectId: nil, name: "Test", createdAt: .now, updatedAt: .now)
                    .insert(db)
                for id in [first, later] {
                    try RecordingSessionRecord(
                        id: id,
                        meetingId: target.meetingID,
                        startedAt: .now,
                        endedAt: id == first ? .now : nil,
                        offsetSeconds: 0,
                        createdAt: .now,
                        updatedAt: .now,
                        transcriptionMode: .batch
                    ).insert(db)
                }
                try RecordingArchiveRecord(
                    sessionId: first,
                    meetingId: target.meetingID,
                    vaultId: target.vaultID,
                    connectionId: target.connectionID,
                    number: 1,
                    audioJSON: audioJSON,
                    state: "saved"
                ).insert(db)
            }
            let settings = ServerAccountSettings(
                processing: .init(location: .remote, remote: .init(
                    summaryModel: "summary-model", transcriptionModel: "gemini-audio", reasoningEffort: "low"
                )),
                summary: .init(style: .eventTimeline),
                outputLanguage: .en,
                analysisLanguages: .init(scope: .all, identifiers: [])
            )
            var processing = RecordingProcessing(
                id: jobID,
                automatic: true,
                liveDraft: false,
                localeIdentifier: "ja_JP",
                method: .cloudTranscription,
                options: .init(exportOptions: .manual, detailLevel: .max),
                generationSettings: .init(
                    modelID: "local",
                    reasoningEffort: "low",
                    detailLevelInstruction: "detail",
                    languageDisplayName: "Japanese",
                    runtimeProvider: .chatGPTSubscription
                ),
                serverSettings: settings
            )
            processing.sessionIDs = [first]
            let bodies = Mutex<[Data]>([])
            ImageURLProtocol.register(origin: target.origin) { request in
                if request.url!.path.hasSuffix("/capabilities") {
                    return (200, [:], Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"],"completeRecordings":true}}"#.utf8))
                }
                if request.url!.path.hasSuffix("/recordings") {
                    return (200, [:], Data("""
                    {"items":[{"id":2,"startedAt":"2026-09-09T00:00:00Z","endedAt":"2026-09-09T00:00:01Z","audio":{"system":{
                    "fileId":"019f0d36-0520-7000-8000-000000000001","contentType":"audio/mp4","size":1,"checksum":null,"contentUrl":"/audio"}}},
                    {"id":1,"startedAt":"2026-09-09T00:00:00Z","endedAt":"2026-09-09T00:00:01Z","audio":{"mic":{"fileId":"\(fileID.uuidString
                        .lowercased())","contentType":"audio/mp4","size":1,"checksum":null,"contentUrl":"/audio"}}}],"nextCursor":null}
                    """.utf8))
                }
                if request.httpMethod == "POST" {
                    if let data = request.httpBody ?? request.httpBodyStream.map(Self.read) { bodies.withLock { $0.append(data) } }
                    return (
                        request.httpMethod == "POST" ? 202 : 200,
                        ["Content-Type": "application/json"],
                        Data(
                            "{\"job\":{\"method\":\"transcript\",\"settings\":{\"model\":\"gpt-5.4\",\"detail\":\"high\",\"reasoningEffort\":\"medium\"},\"outputLanguage\":\"ja\",\"attempts\":1,\"createdAt\":\"2026-09-09T00:00:00.000Z\",\"error\":null,\"id\":\"\(jobID.uuidString)\",\"status\":\"\(status)\",\"stage\":\"saving\"}}"
                                .utf8
                        )
                    )
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
            let service = ServerSummaryService(
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" }),
                synchronize: { _, _ in }
            )
            let stages = Mutex<[String]>([])
            let run = {
                try await service.generate(
                    target,
                    id: jobID,
                    detail: nil,
                    dbQueue: queue,
                    processing: processing,
                    onStage: { stage in stages.withLock { $0.append(stage) } }
                )
            }
            switch status {
            case "cancelled": await #expect(throws: CancellationError.self) { try await run() }
            case "failed": await #expect(throws: ServerSummaryService.Failure.self) { try await run() }
            default: try await run()
            }
            #expect(stages.withLock { $0.last } == "saving")
            let data = try #require(bodies.withLock { $0.first })
            let body = try JSONDecoder().decode(ServerSummaryService.Request.self, from: data)
            #expect(body.input.type == "recording")
            #expect(body.input.recordings?.count == 1)
            #expect(body.input.recordings?.first?.micFileId == fileID.uuidString.lowercased())
            #expect(body.input.transcriptionModel == nil)
            #expect(body.preferences?.processing.remote.transcriptionModel == "gemini-audio")
            #expect(body.preferences?.processing.remote.summaryModel == "summary-model")
            #expect(body.preferences?.processing.remote.reasoningEffort == "low")
            #expect(body.preferences?.outputLanguage == .en)
            #expect(body.preferences?.summary.style == .eventTimeline)
            let sessions = try await queue.read { db in try RecordingSessionRecord.fetchAll(db) }
            #expect((sessions.first { $0.id == first }?.batchCompletedAt != nil) == (status == "succeeded"))
            #expect(sessions.first { $0.id == later }?.batchCompletedAt == nil)
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
    }
#endif
