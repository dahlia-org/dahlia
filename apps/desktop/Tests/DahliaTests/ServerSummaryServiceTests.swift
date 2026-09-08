import DahliaRuntimeSupport
#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    struct ServerSummaryServiceTests {
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
                if path == "/api/v1/capabilities" { return (200, [:], Data(#"{"meetingSummaryGeneration":{"version":1,"sources":["transcript"]}}"#.utf8)) }
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
            #expect(!requested.contains { $0.hasSuffix("/summary") || $0.hasSuffix("/summary/job") })
            #expect(requested.count == (detached ? 1 : 2))
        }

        @Test(arguments: [1, 2])
        func generationRetriesPullContentionBeforeAndAfterTheJob(contendedCall: Int) async throws {
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
            }
            ImageURLProtocol.register(origin: target.origin) { request in
                if request.url!.path == "/api/v1/capabilities" { return (
                    200,
                    [:],
                    Data(#"{"meetingSummaryGeneration":{"version":1,"sources":["transcript"]}}"#.utf8)
                ) }
                if request.httpMethod != "POST" { return (200, [:], Data(#"{"job":null}"#.utf8)) }
                return (200, [:], Data("{\"job\":{\"id\":\"\(id.uuidString)\",\"status\":\"succeeded\"}}".utf8))
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
                    if call == contendedCall { throw TextContentError.changed }
                }
            )
            try await service.generate(target, id: id, detail: nil, dbQueue: queue)
            #expect(pulls.withLock { $0 } == 3)
        }

        @Test(arguments: [String?.none, "concise"])
        func sendsOnlyIdAndDetailAndReadsDurableState(detail: String?) async throws {
            let origin = "https://\(UUID().uuidString).example.test"
            let id = UUID.v7()
            let target = ServerSummaryService.Target(vaultID: .v7(), meetingID: .v7(), connectionID: .v7(), origin: origin)
            let posts = Mutex<[Data]>([])
            ImageURLProtocol.register(origin: origin) { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                if request.url?.path == "/api/v1/capabilities" {
                    return (200, [:], Data(#"{"meetingSummaryGeneration":{"version":1,"sources":["transcript"]}}"#.utf8))
                }
                #expect(request.url?
                    .path ==
                    "/api/v1/vaults/\(target.vaultID.uuidString.lowercased())/meetings/\(target.meetingID.uuidString.lowercased())/summary" +
                    (request.httpMethod == "POST" ? "" : "/job"))
                if request.httpMethod == "POST", let body = request.httpBody ?? request.httpBodyStream.map(Self.read) {
                    posts.withLock { $0.append(body) }
                }
                return (200, [:], Data("{\"job\":{\"id\":\"\(id.uuidString.lowercased())\",\"status\":\"processing\",\"error\":null}}".utf8))
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
                        {"data":[{"id":"available"},{"id":"codex-auto-review"}],"models":[
                          {"slug":"available","display_name":"Available",
                           "supported_reasoning_levels":[{"effort":"max"}],"default_reasoning_level":"max"},
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
            #expect(models.map(\.id) == ["available"])
            #expect(models.first?.supportedReasoningLevels.map(\.effort) == ["max"])
            #expect(models.first?.defaultReasoningLevel == "max")
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
            #expect(response.settings?.summary?.methodSettings.transcript.model == "catalog.ai.model")
            #expect(response.settings?.summary?.method == "transcript")
            let patch = try JSONEncoder().encode(ServerAccountSettings.Patch(outputLanguage: .en))
            let json = try #require(JSONSerialization.jsonObject(with: patch) as? [String: String])
            #expect(json == ["outputLanguage": "en"])
        }

        @Test
        func summaryDetailIsIndependentOfMethod() throws {
            let body = Data(
                """
                {"method":"audio","detail":"standard","methodSettings":{
                  "transcript":{"model":"gpt-5.4","reasoningEffort":"high"},
                  "audio":{"model":"gemini-3-8-flash","reasoningEffort":"medium"}
                }}
                """.utf8
            )
            var summary = try JSONDecoder().decode(ServerAccountSettings.Summary.self, from: body)
            #expect(summary.selectedSettings?.model == "gemini-3-8-flash")
            #expect(summary.selectedSettings?.reasoningEffort == "medium")
            #expect(summary.detailLevel == .standard)
            summary.method = "transcript"
            #expect(summary.detailLevel == .standard)
            summary.method = "future"
            #expect(summary.detailLevel == .standard)
            summary.method = "audio"
            summary.methodSettings.audio = nil
            #expect(summary.detailLevel == .standard)
        }

        @Test(arguments: [
            ("gemini-3-8-flash", ["text", "image", "audio"], true),
            ("gemini-3-7-flash", ["audio"], true),
            ("gemini-text-only", ["text"], false),
            ("other-audio", ["audio"], false),
        ])
        func audioModelChoicesRequireGeminiAndAudioInput(id: String, inputs: [String], expected: Bool) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "slug": id, "display_name": id, "supported_reasoning_levels": [], "input_modalities": inputs,
            ])
            let model = try JSONDecoder().decode(ServerSummaryService.Model.self, from: data)
            #expect(model.supportsAudioSummary == expected)
        }

        @Test(arguments: ["{}", #"{"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"]}}"#, #"{"meetingSummaryGeneration":{"version":2}}"#])
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
        func encodesCommonSummaryDetailPatch() throws {
            let patch = ServerAccountSettings.Patch(summary: .init(detail: "concise"))
            let data = try JSONEncoder().encode(patch)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
            #expect(json == ["summary": ["detail": "concise"]])
            let response = try JSONDecoder().decode(ServerAccountSettings.Response.self, from: Data(#"{"settings":null}"#.utf8))
            #expect(response.settings == nil)
        }

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
    }
#endif
