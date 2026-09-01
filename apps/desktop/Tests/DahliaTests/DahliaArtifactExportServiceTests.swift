import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct DahliaArtifactExportServiceTests {
        private let artifactID = "019cc4dd-e5c5-7bd4-94e0-98df9cc40db9"

        @Test
        func createsPrivateHTMLArtifactWithBearerToken() async throws {
            let connectionID = UUID.v7()
            let html = "<!doctype html><h1>Summary</h1>"
            let session = makeSession { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.absoluteString == "https://dahlia.example/api/v1/artifacts")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/html")
                #expect(request.value(forHTTPHeaderField: "Content-Disposition") == "attachment; filename=\"summary.html\"")
                #expect(request.value(forHTTPHeaderField: "Content-Length") == String(Data(html.utf8).count))
                return (
                    201,
                    ["Location": "https://dahlia.example/api/v1/artifacts/\(artifactID)"],
                    responseBody()
                )
            }

            let result = try await DahliaArtifactExportService.export(
                html: html,
                connectionID: connectionID,
                origin: "https://dahlia.example",
                urlSession: session,
                tokenProvider: { id in
                    #expect(id == connectionID)
                    return "access-token"
                }
            )

            #expect(result.url.absoluteString == "https://dahlia.example/api/v1/artifacts/\(artifactID)")
            #expect(result.wasCreated)
        }

        @Test
        func replacesAnExistingCanonicalArtifact() async throws {
            let existingURL = try #require(URL(string: "https://dahlia.example/api/v1/artifacts/\(artifactID)"))
            let session = makeSession { request in
                #expect(request.httpMethod == "PUT")
                #expect(request.url == existingURL)
                return (200, [:], responseBody())
            }

            let result = try await DahliaArtifactExportService.export(
                html: "<p>Updated</p>",
                connectionID: .v7(),
                origin: "https://dahlia.example",
                existingURL: existingURL,
                urlSession: session,
                tokenProvider: { _ in "access-token" }
            )

            #expect(result.url == existingURL)
            #expect(!result.wasCreated)
        }

        @Test
        func rejectsLocationThatDoesNotMatchCreatedArtifactID() async {
            let session = makeSession { _ in
                (
                    201,
                    ["Location": "https://dahlia.example/api/v1/artifacts/019cc4dd-e5c5-7bd4-94e0-98df9cc40dba"],
                    responseBody()
                )
            }

            await #expect(throws: DahliaArtifactExportError.self) {
                try await DahliaArtifactExportService.export(
                    html: "<p>Summary</p>",
                    connectionID: .v7(),
                    origin: "https://dahlia.example",
                    urlSession: session,
                    tokenProvider: { _ in "access-token" }
                )
            }
        }

        @Test
        func deletesOnlyCanonicalSameOriginArtifact() async throws {
            let url = try #require(URL(string: "https://dahlia.example/api/v1/artifacts/\(artifactID)"))
            let session = makeSession { request in
                #expect(request.httpMethod == "DELETE")
                #expect(request.url == url)
                return (204, [:], Data())
            }

            try await DahliaArtifactExportService.delete(
                url: url,
                connectionID: .v7(),
                origin: "https://dahlia.example",
                urlSession: session,
                tokenProvider: { _ in "access-token" }
            )
        }

        private func responseBody() -> Data {
            Data(#"{"id":"\#(artifactID)","visibility":"private","contentType":"text/html"}"#.utf8)
        }

        private func makeSession(
            handler: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)
        ) -> URLSession {
            ArtifactURLProtocol.handler = handler
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ArtifactURLProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    private final class ArtifactURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler,
                  let url = request.url else { return }
            let (status, headers, data) = handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
