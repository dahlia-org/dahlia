#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct DahliaTokenBrokerTests {
        @Test func pendingDatabricksAuthenticationDoesNotBlockChatToken() async throws {
            let root = URL(filePath: "/tmp/auth-parallel-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: root) }
            let helper = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let clients = Mutex<[Int32: pid_t]>([:])
            let resolve: DahliaTokenBrokerAuthorization.ClientResolver = { descriptor in
                let pid = clients.withLock { values in
                    if let pid = values[descriptor] { return pid }
                    let pid: pid_t = values.isEmpty ? 42 : 41
                    values[descriptor] = pid
                    return pid
                }
                return .init(executableURL: helper, parentPID: pid)
            }
            let chat = DahliaTokenBrokerAuthorization(clientResolver: resolve)
            let inference = DahliaTokenBrokerAuthorization(clientResolver: resolve)
            let chatID = UUID()
            let inferenceID = UUID()
            chat.register(profile: .development, connectionID: chatID, appServerPID: 41, helperURL: helper)
            inference.register(profile: .development, connectionID: inferenceID, provider: .databricks, appServerPID: 42, helperURL: helper)
            let gate = DatabricksAuthorizationGate()
            let (entered, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let server = DahliaTokenBrokerServer(authorizations: [chat, inference]) { _, provider in
                if provider == .databricks {
                    continuation.yield(())
                    await gate.wait()
                }
                return "token"
            }
            try server.start(profile: .development, applicationSupportDirectory: root)
            defer { server.stop() }
            let pending = Task {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: inferenceID, provider: .databricks, profile: .development, applicationSupportDirectory: root
                    )
                }
            }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            let chatResult = try await withBrokerClientThread {
                Result {
                    let client = try connect(profile: .development, applicationSupportDirectory: root)
                    defer { Darwin.close(client) }
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                        throw POSIXError(.ETIMEDOUT)
                    }
                    var payload = try JSONEncoder().encode(DahliaTokenBrokerProtocol.Request(connectionID: chatID))
                    payload.append(0x0A)
                    try DahliaTokenBrokerProtocol.writeAll(payload, to: client)
                    return try JSONDecoder().decode(DahliaTokenBrokerProtocol.Response.self, from: DahliaTokenBrokerProtocol.readLine(from: client))
                }
            }
            await gate.release()
            #expect(try await pending.value == "token")
            #expect(try chatResult.get().token == "token")
        }

        @Test func chatAndMacInferenceGrantsRemainIndependent() async throws {
            let root = URL(filePath: "/tmp/auth-runtimes-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: root) }
            let helper = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let parentPID = Mutex<pid_t>(41)
            let resolve: DahliaTokenBrokerAuthorization.ClientResolver = { _ in
                .init(executableURL: helper, parentPID: parentPID.withLock { $0 })
            }
            let chat = DahliaTokenBrokerAuthorization(clientResolver: resolve)
            let inference = DahliaTokenBrokerAuthorization(clientResolver: resolve)
            let chatID = UUID()
            let inferenceID = UUID()
            chat.register(profile: .development, connectionID: chatID, appServerPID: 41, helperURL: helper)
            inference.register(profile: .development, connectionID: inferenceID, provider: .databricks, appServerPID: 42, helperURL: helper)
            let server = DahliaTokenBrokerServer(authorizations: [chat, inference]) { id, _ in id.uuidString }
            try server.start(profile: .development, applicationSupportDirectory: root)
            defer { server.stop() }

            for pid: pid_t in [41, 42] {
                parentPID.withLock { $0 = pid }
                let ownID = pid == 41 ? chatID : inferenceID
                let ownProvider: DahliaTokenBrokerProtocol.Provider = pid == 41 ? .dahlia : .databricks
                let otherID = pid == 41 ? inferenceID : chatID
                let otherProvider: DahliaTokenBrokerProtocol.Provider = pid == 41 ? .databricks : .dahlia
                let token = try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: ownID, provider: ownProvider, profile: .development, applicationSupportDirectory: root
                    )
                }
                #expect(token == ownID.uuidString)
                await #expect(throws: (any Error).self) {
                    try await withBrokerClientThread {
                        try DahliaTokenBrokerProtocol.requestToken(
                            connectionID: otherID, provider: otherProvider, profile: .development, applicationSupportDirectory: root
                        )
                    }
                }
            }
            chat.clear(profile: .development)
            let token = try await withBrokerClientThread {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: inferenceID, provider: .databricks, profile: .development, applicationSupportDirectory: root
                )
            }
            #expect(token == inferenceID.uuidString)
            inference.clear(profile: .development)
            await #expect(throws: (any Error).self) {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: inferenceID, provider: .databricks, profile: .development, applicationSupportDirectory: root
                    )
                }
            }
        }

        @Test
        func developmentBrokerReturnsConnectionTokenOverPrivateSocket() async throws {
            let rootURL = URL(filePath: "/tmp/dahlia-token-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let connectionID = UUID()
            let helperURL = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let client = Mutex(DahliaTokenBrokerAuthorization.Client(executableURL: helperURL, parentPID: 41))
            let authorization = DahliaTokenBrokerAuthorization { _ in
                client.withLock { $0 }
            }
            authorization.register(
                profile: .development,
                connectionID: connectionID,
                appServerPID: 42,
                helperURL: helperURL
            )
            let requestedIDs = Mutex<[UUID]>([])
            let server = DahliaTokenBrokerServer(authorizations: [authorization]) { requestedID, provider in
                #expect(provider == .dahlia)
                requestedIDs.withLock { $0.append(requestedID) }
                #expect(requestedID == connectionID)
                return "short-lived-token"
            }
            try server.start(profile: .development, applicationSupportDirectory: rootURL)
            defer { server.stop() }

            await #expect(throws: (any Error).self) {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: connectionID,
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }
            }
            client.withLock { $0 = .init(executableURL: URL(filePath: "/tmp/dahlia-mcp"), parentPID: 42) }
            #expect(!authorization.authorizesClient(0, profile: .development))
            client.withLock { $0 = .init(executableURL: helperURL, parentPID: 42) }
            await #expect(throws: (any Error).self) {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: UUID(),
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }
            }
            await #expect(throws: (any Error).self) {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: connectionID,
                        provider: .databricks,
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }
            }
            let token = try await withBrokerClientThread {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: connectionID,
                    profile: .development,
                    applicationSupportDirectory: rootURL
                )
            }

            #expect(token == "short-lived-token")
            #expect(requestedIDs.withLock { $0 } == [connectionID])
            let socketURL = DahliaTokenBrokerProtocol.socketURL(
                profile: .development,
                applicationSupportDirectory: rootURL
            )
            #expect(try permissions(at: socketURL) == 0o600)
            #expect(try permissions(at: socketURL.deletingLastPathComponent()) == 0o700)
        }

        @Test
        func stalledAuthorizedClientDoesNotBlockTheNextTokenRequest() async throws {
            let rootURL = URL(filePath: "/tmp/dahlia-token-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let connectionID = UUID()
            let helperURL = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let clientResolved = DispatchSemaphore(value: 0)
            let authorization = DahliaTokenBrokerAuthorization { _ in
                clientResolved.signal()
                return .init(executableURL: helperURL, parentPID: 42)
            }
            authorization.register(
                profile: .development,
                connectionID: connectionID,
                appServerPID: 42,
                helperURL: helperURL
            )
            let server = DahliaTokenBrokerServer(authorizations: [authorization]) { _, _ in "token" }
            try server.start(profile: .development, applicationSupportDirectory: rootURL)
            defer { server.stop() }
            let stalledClient = try connect(
                profile: .development,
                applicationSupportDirectory: rootURL
            )
            defer { Darwin.close(stalledClient) }
            let wasAccepted = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: clientResolved.wait(timeout: .now() + 1) == .success)
                }
            }
            #expect(wasAccepted)

            let clock = ContinuousClock()
            let start = clock.now
            let token = try await withBrokerClientThread {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: connectionID,
                    profile: .development,
                    applicationSupportDirectory: rootURL
                )
            }

            #expect(token == "token")
            #expect(start.duration(to: clock.now) < .seconds(3))
        }

        @Test func explicitRuntimeProfilesHaveSeparateSockets() {
            let root = URL(filePath: "/tmp/auth-profile-test")
            let production = DahliaTokenBrokerProtocol.socketURL(profile: .production, applicationSupportDirectory: root)
            let development = DahliaTokenBrokerProtocol.socketURL(profile: .development, applicationSupportDirectory: root)
            #expect(production != development)
            #expect(production.path.contains("/Dahlia/"))
            #expect(development.path.contains("/Dahlia-Development/"))
        }

        @Test func grantRevokedWhileResolvingDoesNotReturnToken() async throws {
            let root = URL(filePath: "/tmp/auth-revoke-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID()
            let helper = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let authorization = DahliaTokenBrokerAuthorization { _ in .init(executableURL: helper, parentPID: 42) }
            authorization.register(profile: .development, connectionID: id, provider: .databricks, appServerPID: 42, helperURL: helper)
            let gate = DatabricksAuthorizationGate()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let server = DahliaTokenBrokerServer(authorizations: [authorization]) { _, provider in
                #expect(provider == .databricks)
                continuation.yield(())
                await gate.wait()
                return "must-not-return"
            }
            try server.start(profile: .development, applicationSupportDirectory: root)
            defer { server.stop() }
            let request = Task {
                try await withBrokerClientThread {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: id,
                        provider: .databricks,
                        profile: .development,
                        applicationSupportDirectory: root
                    )
                }
            }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            authorization.clear(profile: .development)
            await gate.release()
            await #expect(throws: (any Error).self) { try await request.value }
        }

        @Test(arguments: [true, false])
        func abandonedBrowserResolutionDoesNotBlockNextRequest(replacesGrant: Bool) async throws {
            let root = URL(filePath: "/tmp/auth-abandon-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: root) }
            let oldID = UUID()
            let nextID = UUID()
            let helper = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/auth-helper")
            let authorization = DahliaTokenBrokerAuthorization { _ in .init(executableURL: helper, parentPID: 42) }
            authorization.register(profile: .development, connectionID: oldID, provider: .databricks, appServerPID: 42, helperURL: helper)
            let (entered, continuation) = AsyncStream<Void>.makeStream()
            let (cancelled, cancellation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish()
                cancellation.finish()
            }
            let server = DahliaTokenBrokerServer(authorizations: [authorization]) { id, _ in
                if id == oldID {
                    continuation.yield(())
                    do { try await Task.sleep(for: .seconds(5)) } catch {
                        cancellation.yield(())
                        throw error
                    }
                    Issue.record("Obsolete browser resolution was not cancelled")
                }
                return "next-token"
            }
            try server.start(profile: .development, applicationSupportDirectory: root)
            defer { server.stop() }
            let client = try connect(profile: .development, applicationSupportDirectory: root)
            var payload = try JSONEncoder().encode(DahliaTokenBrokerProtocol.Request(connectionID: oldID, provider: .databricks))
            payload.append(0x0A)
            try DahliaTokenBrokerProtocol.writeAll(payload, to: client)
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            if replacesGrant {
                authorization.register(profile: .development, connectionID: nextID, appServerPID: 42, helperURL: helper)
            } else {
                Darwin.close(client)
            }
            var cancellationIterator = cancelled.makeAsyncIterator()
            _ = await cancellationIterator.next()
            if replacesGrant {
                Darwin.close(client)
            } else {
                authorization.register(profile: .development, connectionID: nextID, appServerPID: 42, helperURL: helper)
            }
            let token = try await withBrokerClientThread {
                try DahliaTokenBrokerProtocol.requestToken(connectionID: nextID, profile: .development, applicationSupportDirectory: root)
            }
            #expect(token == "next-token")
        }

        private func connect(profile: DahliaRuntimeProfile, applicationSupportDirectory: URL) throws -> Int32 {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let socketURL = DahliaTokenBrokerProtocol.socketURL(
                profile: profile,
                applicationSupportDirectory: applicationSupportDirectory
            )
            var address = try DahliaTokenBrokerProtocol.unixAddress(path: socketURL.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        DahliaTokenBrokerProtocol.unixAddressLength(path: socketURL.path)
                    )
                }
            }
            guard result == 0 else {
                Darwin.close(descriptor)
                throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
            }
            return descriptor
        }

        private func permissions(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        }
    }
#endif
