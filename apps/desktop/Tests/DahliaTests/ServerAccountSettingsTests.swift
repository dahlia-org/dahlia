#if canImport(Testing)
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ServerAccountSettingsTests {
        @Test
        func modelCatalogDistinguishesUnknownFailedAndLoadedEmptyStates() {
            var state = ServerAccountSettingsModel.State()
            #expect(!state.isModelCatalogLoaded)
            state.isAvailable = true
            #expect(state.summaryModels.isEmpty && state.isModelCatalogLoaded)
            state.modelErrorMessage = "catalog failed"
            #expect(!state.isModelCatalogLoaded)
            state.modelErrorMessage = nil
            state.errorMessage = "capabilities failed"
            #expect(!state.isModelCatalogLoaded)
        }

        @Test
        func capabilitiesFailureLeavesModelCatalogUnknownUntilRecovery() async {
            let account = connection()
            let fails = Mutex(true)
            let modelReads = Mutex(0)
            ImageURLProtocol.register(origin: account.origin) { request in
                if request.url!.path == "/api/v1/capabilities" {
                    if fails.withLock({ $0 }) { return (503, [:], Data()) }
                    return (200, [:], Data(#"{"meetingSummaryGeneration":{"version":2,"sources":["transcript"]}}"#.utf8))
                }
                modelReads.withLock { $0 += 1 }
                return (200, [:], Data(#"{"data":[],"models":[]}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            let model = model()
            model.updateConnections([account])
            await model.refresh(connectionID: account.id)?.value
            let failed = model.state(for: account.id)
            #expect(!failed.isModelCatalogLoaded)
            #expect(!failed.isAvailable && failed.errorMessage != nil)
            #expect(failed.modelErrorMessage == nil && modelReads.withLock { $0 } == 0)
            fails.withLock { $0 = false }
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).isModelCatalogLoaded)
            #expect(model.state(for: account.id).summaryModels.isEmpty)
            model.updateConnections([])
        }

        @Test
        func refreshDoesNotWriteSettingsOrReloadModelCatalog() async {
            let account = connection()
            let requests = Mutex<[String]>([])
            ImageURLProtocol.register(origin: account.origin) { request in
                let path = request.url!.path
                requests.withLock { $0.append(path) }
                let body: String = switch path {
                case "/api/v1/capabilities":
                    #"{"meetingSummaryGeneration":{"version":2,"sources":["transcript","audio"],"completeRecordings":true}}"#
                case "/api/v1/models":
                    #"{"data":[],"models":[]}"#
                default:
                    Self.response("en")
                }
                return (200, [:], Data(body.utf8))
            }
            defer { ImageURLProtocol.remove(origin: account.origin) }
            let model = model()
            model.updateConnections([account])
            await model.refresh(connectionID: account.id)?.value
            await model.refresh(connectionID: account.id)?.value
            await model.refresh(connectionID: account.id)?.value
            #expect(requests.withLock { !$0.contains("/api/v1/account/settings") })
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/models" }.count } == 1)
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/capabilities" }.count } == 1)
            await model.refresh(connectionID: account.id, reloadModels: true)?.value
            #expect(requests.withLock { $0.filter { $0 == "/api/v1/models" }.count } == 2)
            model.updateConnections([])
        }

        @Test(arguments: [3, 4])
        func modelReloadSurvivesReplacementRefresh(blockedRequest: Int) async {
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
                    body = #"{"meetingSummaryGeneration":{"version":2,"sources":["transcript"]}}"#
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
            await model.refresh(connectionID: account.id)?.value
            #expect(modelReads.withLock { $0 } == 1)
            // Interrupt the explicit reload during capabilities or models.
            let reload = model.refresh(connectionID: account.id, reloadModels: true)
            await gate.waitUntilStarted()
            #expect(!model.state(for: account.id).isModelCatalogLoaded)
            await model.refresh(connectionID: account.id)?.value
            #expect(model.state(for: account.id).summaryModels.map(\.id) == ["refreshed"])
            await gate.release()
            await reload?.value
            #expect(model.state(for: account.id).summaryModels.map(\.id) == ["refreshed"])
            #expect(model.state(for: account.id).isAvailable)
            #expect(model.state(for: account.id).isModelCatalogLoaded)
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
                client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: tokenProvider)
            )
        }

        private nonisolated static func response(_ language: String) -> String {
            "{\"settings\":{\"analysisLanguages\":{\"scope\":\"selected\",\"identifiers\":[\"\(language)\"]}}}"
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
