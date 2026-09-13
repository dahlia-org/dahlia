#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import HTTPTypes
    import OpenAPIRuntime
    import Testing
    @testable import Dahlia

    struct CloudWorkspaceDiscoveryTests {
        @Test
        func requestsAccessibleWorkspacesIncludingDirectUserShares() async throws {
            let result = try await CloudWorkspaceDiscovery.fetch(connection: connection, token: "test", transport: DiscoveryTransport { request in
                let url = try #require(request.url)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
                #expect(url.path == "/api/v1/workspaces")
                #expect(url.query == nil)
                return response(url, body: workspacePage("2"))
            })
            #expect(result.count == 1)
            #expect(result.first?.role == "viewer")
        }

        @Test
        func doesNotHideServerFailures() async throws {
            await #expect(throws: (any Error).self) {
                try await CloudWorkspaceDiscovery.fetch(connection: connection, token: "test", transport: DiscoveryTransport { request in
                    let url = try #require(request.url)
                    return response(url, status: 500, body: "{}")
                })
            }
        }

    }

    private var connection: DahliaAccountConnectionRecord {
        .init(id: UUID(), origin: "https://example.com", clientID: "test", createdAt: .now)
    }

    private func workspacePage(_ suffix: String, role: String = "viewer") -> String {
        """
        {"items":[{"workspaceId":"\(TypeID.encode(
            UUID(uuidString: "019d3f46-7e0d-7d21-98d9-f1456c0bfb5" + suffix)!,
            as: .workspace
        ))","name":"Workspace",
        "organizationId":"\(TypeID.encode(
            UUID(uuidString: "019d3f46-7e0d-7d21-98d9-f1456c0bfb51")!,
            as: .organization
        ))","revision":1,"createdAt":"2026-09-03T00:00:00.000Z","updatedAt":"2026-09-03T00:00:00.000Z","role":"\(role)"}],"nextCursor":null}
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
