#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct CloudVaultDiscoveryTests {
        @Test
        func combinesOwnedAndSharedVaultsWithoutDuplicates() async throws {
            let result = try await CloudVaultDiscovery.fetch(connection: connection, token: "test") { request in
                let url = try #require(request.url)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
                if url.path == "/api/v1/organizations" {
                    return response(url, body: #"[{"id":"a"},{"id":"b"}]"#)
                }
                let organization = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first?.value
                return response(url, body: organization == nil ? vaultPage("1", role: "owner") : vaultPage("2"))
            }
            #expect(result.count == 2)
            #expect(result.map(\.role) == ["owner", "member"])
        }

        @Test
        func keepsPersonalVaultsWhenMembershipWasRevoked() async throws {
            let result = try await CloudVaultDiscovery.fetch(connection: connection, token: "test") { request in
                let url = try #require(request.url)
                if url.path == "/api/v1/organizations" {
                    return response(url, body: #"[{"id":"revoked"}]"#)
                }
                return url.query == nil ? response(url, body: vaultPage("1", role: "owner"))
                    : response(url, status: 403, body: "{}")
            }
            #expect(result.count == 1)
        }

        @Test
        func supportsOlderServerAndDoesNotHideServerFailures() async throws {
            let result = try await CloudVaultDiscovery.fetch(connection: connection, token: "test") { request in
                let url = try #require(request.url)
                return url.path == "/api/v1/organizations" ? response(url, status: 404, body: "{}")
                    : response(url, body: vaultPage("1"))
            }
            #expect(result.count == 1)
            await #expect(throws: URLError.self) {
                try await CloudVaultDiscovery.fetch(connection: connection, token: "test") { request in
                    let url = try #require(request.url)
                    return url.path == "/api/v1/organizations" ? response(url, status: 500, body: "{}")
                        : response(url, body: vaultPage("1"))
                }
            }
        }
    }

    private var connection: DahliaAccountConnectionRecord {
        .init(id: UUID(), origin: "https://example.com", clientID: "test", createdAt: .now)
    }

    private func vaultPage(_ suffix: String, role: String = "member") -> String {
        """
        {"items":[{"vaultId":"019d3f46-7e0d-7d21-98d9-f1456c0bfb5\(suffix)","name":"Vault",
        "revision":1,"createdAt":"2026-09-03T00:00:00.000Z","role":"\(role)"}]}
        """
    }

    private func response(_ url: URL, status: Int = 200, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
#endif
