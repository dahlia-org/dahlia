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
            let helperURL = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { requestedID in
                requestedIDs.withLock { $0.append(requestedID) }
                #expect(requestedID == connectionID)
                return "short-lived-token"
            }
            try server.start(profile: .development, applicationSupportDirectory: rootURL)
            defer { server.stop() }

            await #expect(throws: (any Error).self) {
                try await Task.detached {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: connectionID,
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }.value
            }
            client.withLock { $0 = .init(executableURL: URL(filePath: "/tmp/dahlia-mcp"), parentPID: 42) }
            #expect(!authorization.authorizesClient(0, profile: .development))
            client.withLock { $0 = .init(executableURL: helperURL, parentPID: 42) }
            await #expect(throws: (any Error).self) {
                try await Task.detached {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: UUID(),
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }.value
            }
            let token = try await Task.detached {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: connectionID,
                    profile: .development,
                    applicationSupportDirectory: rootURL
                )
            }.value

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
            let helperURL = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")
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
            let server = DahliaTokenBrokerServer(authorization: authorization) { _ in "token" }
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
            let token = try await Task.detached {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: connectionID,
                    profile: .development,
                    applicationSupportDirectory: rootURL
                )
            }.value

            #expect(token == "token")
            #expect(start.duration(to: clock.now) < .seconds(3))
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
