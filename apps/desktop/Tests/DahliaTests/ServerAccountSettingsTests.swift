#if canImport(Testing)
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ServerAccountSettingsTests {
        @Test
        func initializesOnceAndKeepsMemoryReadOnlyAfterFailureOrDisconnect() async {
            let account = connection()
            let requests = Mutex<[String]>([])
            let initialized = Mutex(false)
            ImageURLProtocol.register(origin: account.origin) { request in
                requests.withLock { $0.append(request.httpMethod!) }
                if request.httpMethod == "PATCH" { initialized.withLock { $0 = true } }
                let body = initialized.withLock { $0 } ? Self.response("en") : "{\"settings\":null}"
                return (200, [:], Data(body.utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            let model = model()
            model.updateConnections([account])
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).settings?.outputLanguage == .en)
            #expect(requests.withLock { $0.filter { $0 == "PATCH" }.count } == 1)
            await model.refresh(connectionID: account.id)?.value
            #expect(requests.withLock { $0.filter { $0 == "PATCH" }.count } == 1)
            ImageURLProtocol.register(origin: account.origin) { _ in (503, [:], Data()) }
            await model.refresh(connectionID: account.id)?.value
            #expect(!model.state(for: account.id).canEdit)
            #expect(model.state(for: account.id).settings?.outputLanguage == .en)
            model.networkAvailabilityChanged(false)
            #expect(model.save(.init(outputLanguage: .ja), connectionID: account.id) == nil)
            #expect(model.refresh(connectionID: account.id) == nil)
            ImageURLProtocol.register(origin: account.origin) { _ in (200, [:], Data(Self.response("fr").utf8)) }
            model.networkAvailabilityChanged(true)
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).settings?.outputLanguage == .fr)
            #expect(model.state(for: account.id).canEdit)
            model.updateConnections([])
            #expect(model.states.isEmpty)
        }

        @Test
        func offlineStartupDoesNotInitializeOrGateOtherWork() {
            let model = model()
            model.networkAvailabilityChanged(false)
            let account = connection()
            model.updateConnections([account])
            #expect(model.state(for: account.id).settings == nil)
            #expect(!model.state(for: account.id).canEdit)
            #expect(!model.state(for: account.id).isLoading)
        }

        @Test(arguments: [false, true])
        func staleRequestCannotOverwriteNewerSettings(changesAccount: Bool) async {
            let account = connection()
            let gate = SettingsTokenGate()
            let model = model(tokenProvider: { _, _ in await gate.token() })
            ImageURLProtocol.register(origin: account.origin) { request in
                let language = request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" ? "ja" : "en"
                return (200, [:], Data(Self.response(language).utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            model.updateConnections([account])
            let oldRequest = model.refresh(connectionID: account.id)
            await gate.waitUntilStarted()
            let replacement = DahliaAccountConnection(
                record: account.record, account: .init(id: "different-user", name: nil, email: nil), isCloud: false
            )
            model.updateConnections([changesAccount ? replacement : account])
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).settings?.outputLanguage == .en)
            await gate.release()
            await oldRequest?.value
            #expect(model.state(for: account.id).settings?.outputLanguage == .en)
            model.updateConnections([])
            #expect(model.states.isEmpty)
        }

        @Test(arguments: [false, true])
        func contentReadersFollowReplacementRequestsWithoutCrossingAccounts(changesAccount: Bool) async throws {
            let account = connection()
            let first = SettingsTokenGate()
            let second = SettingsTokenGate()
            let calls = Mutex(0)
            let model = model(tokenProvider: { _, _ in
                let call = calls.withLock { value in value += 1
                    return value
                }
                return await (call == 1 ? first : second).token()
            })
            ImageURLProtocol.register(origin: account.origin) { _ in (200, [:], Data(Self.response("fr").utf8)) }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            model.updateConnections([account])
            let original = model.refresh(connectionID: account.id)
            await first.waitUntilStarted()
            let started = AsyncStream<Void>.makeStream()
            let reader = Task {
                started.continuation.yield(())
                return try await model.loadedSettings(connectionID: account.id)
            }
            var iterator = started.stream.makeAsyncIterator()
            await iterator.next()
            if changesAccount {
                model.updateConnections([DahliaAccountConnection(
                    record: account.record, account: .init(id: "different-user", name: nil, email: nil), isCloud: false
                )])
            } else {
                model.refresh(connectionID: account.id)
            }
            await second.waitUntilStarted()
            await first.release()
            await original?.value
            await second.release()
            if changesAccount {
                await #expect(throws: URLError.self) { try await reader.value }
            } else {
                #expect(try await reader.value.outputLanguage == .fr)
            }
            await model.refresh(connectionID: account.id)?.value
            model.updateConnections([])
        }

        @Test
        func settingsRefreshAndSaveDoNotReloadModelCatalog() async throws {
            let account = connection()
            let requests = Mutex<[String]>([])
            ImageURLProtocol.register(origin: account.origin) { request in
                let path = request.url!.path
                requests.withLock { $0.append(path) }
                let body: String
                switch path {
                case "/api/v1/capabilities":
                    body = #"{"meetingSummaryGeneration":{"version":1,"sources":["transcript","audio"]}}"#
                case "/api/v1/models":
                    body = #"{"data":[],"models":[]}"#
                default:
                    body = Self.response("en")
                }
                return (200, [:], Data(body.utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            let model = model()
            model.updateConnections([account])
            _ = try await model.loadedSettings(connectionID: account.id)
            await model.refresh(connectionID: account.id)?.value
            await model.save(.init(outputLanguage: .en), connectionID: account.id)?.value
            _ = try await model.loadedSettings(connectionID: account.id)
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/models" }.count } == 1)
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/capabilities" }.count } == 1)
            await model.refresh(connectionID: account.id, reloadModels: true)?.value
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/models" }.count } == 2)
            model.updateConnections([])
        }

        @Test(arguments: [4, 5, 6])
        func modelReloadSurvivesReplacementRefresh(blockedRequest: Int) async throws {
            let account = connection()
            let gate = SettingsTokenGate()
            let calls = Mutex(0)
            let modelReads = Mutex(0)
            let model = model(tokenProvider: { _, _ in
                let call = calls.withLock { value in value += 1
                    return value
                }
                return call == blockedRequest ? await gate.token() : "test-token"
            })
            ImageURLProtocol.register(origin: account.origin) { request in
                let body: String
                switch request.url!.path {
                case "/api/v1/capabilities":
                    body = #"{"meetingSummaryGeneration":{"version":1,"sources":["transcript"]}}"#
                case "/api/v1/models":
                    let id: String
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                        id = "canceled"
                    } else {
                        let count = modelReads.withLock { value in value += 1
                            return value
                        }
                        id = count == 1 ? "initial" : "refreshed"
                    }
                    body = """
                    {"data":[{"id":"\(id)"}],"models":[{"slug":"\(id)","display_name":"\(id)","supported_reasoning_levels":[]}]}
                    """
                default:
                    body = Self.response("en")
                }
                return (200, [:], Data(body.utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            model.updateConnections([account])
            _ = try await model.loadedSettings(connectionID: account.id)
            #expect(modelReads.withLock { $0 } == 1)
            // Interrupt the explicit reload during settings, capabilities, or models.
            let reload = model.refresh(connectionID: account.id, reloadModels: true)
            await gate.waitUntilStarted()
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).summaryModels.map(\.id) == ["refreshed"])
            await gate.release()
            await reload?.value
            #expect(model.state(for: account.id).summaryModels.map(\.id) == ["refreshed"])
            #expect(model.state(for: account.id).canEdit)
            let completedReads = modelReads.withLock { $0 }
            await model.refresh(connectionID: account.id)?.value
            #expect(modelReads.withLock { $0 } == completedReads)
            model.updateConnections([])
        }

        private func connection() -> DahliaAccountConnection {
            .init(
                record: .init(id: .v7(), origin: "https://\(UUID().uuidString).example.test", clientID: "test", createdAt: .now),
                account: .init(id: "user", name: nil, email: nil),
                isCloud: false
            )
        }

        private func model(
            tokenProvider: @escaping @Sendable (UUID, Bool) async throws -> String = { _, _ in "test-token" }
        ) -> ServerAccountSettingsModel {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            return ServerAccountSettingsModel(
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: tokenProvider),
                initialValues: { .init(outputLanguage: .en, analysisLanguages: .init(scope: .all, identifiers: [])) }
            )
        }

        private nonisolated static func response(_ language: String) -> String {
            "{\"settings\":{\"outputLanguage\":\"\(language)\",\"analysisLanguages\":{\"scope\":\"all\",\"identifiers\":[]}}}"
        }
    }

    private actor SettingsTokenGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var blocked: CheckedContinuation<String, Never>?
        func token() async -> String {
            if started { return "test-token" }
            started = true
            startWaiter?.resume()
            startWaiter = nil
            return await withCheckedContinuation { blocked = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func release() {
            blocked?.resume(returning: "old-token")
            blocked = nil
        }
    }
#endif
