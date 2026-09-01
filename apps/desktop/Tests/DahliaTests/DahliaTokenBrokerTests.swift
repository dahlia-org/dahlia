#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    struct DahliaTokenBrokerTests {
        @Test
        func developmentBrokerReturnsConnectionTokenOverPrivateSocket() async throws {
            let rootURL = URL(filePath: "/tmp/dahlia-token-broker-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let connectionID = UUID()
            let server = DahliaTokenBrokerServer { requestedID in
                #expect(requestedID == connectionID)
                return "short-lived-token"
            }
            try server.start(profile: .development, applicationSupportDirectory: rootURL)
            defer { server.stop() }

            let token = try await Task.detached {
                try DahliaTokenBrokerProtocol.requestToken(
                    connectionID: connectionID,
                    profile: .development,
                    applicationSupportDirectory: rootURL
                )
            }.value

            #expect(token == "short-lived-token")
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
