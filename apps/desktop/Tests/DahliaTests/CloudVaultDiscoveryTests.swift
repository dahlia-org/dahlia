#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import HTTPTypes
    import OpenAPIRuntime
    import Testing
    @testable import Dahlia

    struct CloudVaultDiscoveryTests {
        @Test
        func combinesOwnedAndSharedVaultsWithoutDuplicates() async throws {
            let result = try await CloudVaultDiscovery.fetch(connection: connection, token: "test", transport: DiscoveryTransport { request in
                let url = try #require(request.url)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
                if url.path == "/api/v1/organizations" {
                    return response(url, body: #"""
                    {"items":[{"id":"org_01m0000000e008000000000001","name":"A","slug":"a"},
                    {"id":"org_01m0000000e008000000000002","name":"B","slug":"b"}],"nextCursor":null}
                    """#)
                }
                let organization = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first?.value
                return response(url, body: organization == nil ? vaultPage("1", role: "owner") : vaultPage("2"))
            })
            #expect(result.count == 2)
            #expect(result.map(\.role) == ["owner", "member"])
        }

        @Test
        func keepsPersonalVaultsWhenMembershipWasRevoked() async throws {
            let result = try await CloudVaultDiscovery.fetch(connection: connection, token: "test", transport: DiscoveryTransport { request in
                let url = try #require(request.url)
                if url.path == "/api/v1/organizations" {
                    return response(url, body: #"{"items":[{"id":"org_01m0000000e008000000000003","name":"R","slug":"r"}],"nextCursor":null}"#)
                }
                return url.query == nil ? response(url, body: vaultPage("1", role: "owner"))
                    : response(url, status: 403, body: "{}")
            })
            #expect(result.count == 1)
        }

        @Test
        func doesNotHideServerFailures() async throws {
            await #expect(throws: (any Error).self) {
                try await CloudVaultDiscovery.fetch(connection: connection, token: "test", transport: DiscoveryTransport { request in
                    let url = try #require(request.url)
                    return url.path == "/api/v1/organizations" ? response(url, status: 500, body: "{}")
                        : response(url, body: vaultPage("1"))
                })
            }
        }

    }

    private var connection: DahliaAccountConnectionRecord {
        .init(id: UUID(), origin: "https://example.com", clientID: "test", createdAt: .now)
    }

    private func vaultPage(_ suffix: String, role: String = "member") -> String {
        """
        {"items":[{"vaultId":"\(TypeID.encode(UUID(uuidString: "019d3f46-7e0d-7d21-98d9-f1456c0bfb5" + suffix)!, as: .vault))","name":"Vault",
        "revision":1,"createdAt":"2026-09-03T00:00:00.000Z","updatedAt":"2026-09-03T00:00:00.000Z","role":"\(role)"}],"nextCursor":null}
        """
    }

    private func response(_ url: URL, status: Int = 200, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private struct DiscoveryTransport: ClientTransport {
        let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        init(_ load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) { self.load = load }
        func send(_ request: HTTPRequest, body _: HTTPBody?, baseURL: URL, operationID _: String) async throws -> (HTTPResponse, HTTPBody?) {
            var urlRequest = URLRequest(url: URL(string: request.path ?? "/", relativeTo: baseURL)!)
            for field in request.headerFields {
                urlRequest.setValue(field.value, forHTTPHeaderField: field.name.rawName)
            }
            let (data, response) = try await load(urlRequest)
            let status = try #require(response as? HTTPURLResponse).statusCode
            return (HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]), HTTPBody(data))
        }
    }
#endif
