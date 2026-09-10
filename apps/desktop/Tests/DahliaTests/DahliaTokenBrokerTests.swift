#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct DahliaTokenBrokerTests {
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { requestedID, provider in
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { _, _ in "token" }
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { _, provider in
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { id, _ in
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
