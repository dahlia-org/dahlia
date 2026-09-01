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
            await #expect(throws: (any Error).self) {
                try await Task.detached {
                    try DahliaTokenBrokerProtocol.requestToken(
                        connectionID: connectionID,
                        profile: .development,
                        applicationSupportDirectory: rootURL
                    )
                }.value
            }
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

        private func permissions(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        }
    }
#endif
