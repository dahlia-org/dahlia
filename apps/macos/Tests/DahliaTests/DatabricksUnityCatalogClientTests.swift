#if canImport(Testing)
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct DatabricksUnityCatalogClientTests {
        private let host = "catalog-\(UUID().uuidString.lowercased()).example"

        @Test(arguments: [false, true])
        func readsEveryPageIncludingEmptyPages(schemas: Bool) async throws {
            let session = StorageStubURLProtocol.session(host: host) { request in
                let key = schemas ? "schemas" : "catalogs"
                if request.query("page_token") == nil { return .json(#"{"\#(key)":[],"next_page_token":"page 2"}"#) }
                return .json(#"{"\#(key)":[{"name":"zebra"},{"name":"alpha"}]}"#)
            }
            defer { session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let client = try DatabricksUnityCatalogClient(
                host: #require(URL(string: "https://\(host)")), session: session,
                authorization: ProviderStorageAuthorization(accessToken: "fixed", validate: {})
            )
            let values = try await (schemas ? client.schemas(in: "main&shared") : client.catalogs())
            #expect(values == ["alpha", "zebra"])
            let requests = StorageStubURLProtocol.requests(host: host)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.query("max_results") == "0" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixed" })
            #expect(requests.last?.query("page_token") == "page 2")
            #expect(requests.first?.query("catalog_name") == (schemas ? "main&shared" : nil))
        }

        @Test
        func createsOnlyASchemaInTheChosenCatalog() async throws {
            let session = StorageStubURLProtocol.session(host: host) { _ in .json(#"{"name":"new_schema","catalog_name":"main"}"#) }
            defer { session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let client = try DatabricksUnityCatalogClient(
                host: #require(URL(string: "https://\(host)")), session: session,
                authorization: ProviderStorageAuthorization(accessToken: "fixed", validate: {})
            )
            #expect(try await client.createSchema(named: "new_schema", in: "main") == "new_schema")
            let request = try #require(StorageStubURLProtocol.requests(host: host).first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/2.1/unity-catalog/schemas")
            #expect(request.jsonBody["name"] as? String == "new_schema")
            #expect(request.jsonBody["catalog_name"] as? String == "main")
            #expect(request.jsonBody.count == 2)
        }

        @Test
        func invalidationBetweenPagesStopsRequests() async throws {
            let valid = Mutex(true)
            let session = StorageStubURLProtocol.session(host: host) { _ in
                valid.withLock { $0 = false }
                return .json(#"{"catalogs":[{"name":"main"}],"next_page_token":"next"}"#)
            }
            defer { session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let client = try DatabricksUnityCatalogClient(
                host: #require(URL(string: "https://\(host)")), session: session,
                authorization: ProviderStorageAuthorization(accessToken: "fixed") {
                    guard valid.withLock({ $0 }) else { throw CancellationError() }
                }
            )
            await #expect(throws: CancellationError.self) { try await client.catalogs() }
            #expect(StorageStubURLProtocol.requests(host: host).count == 1)
            await #expect(throws: CancellationError.self) { try await client.createSchema(named: "new", in: "main") }
            #expect(StorageStubURLProtocol.requests(host: host).count == 1)
        }

        @Test
        func permissionsAndPaginationFailuresAreReported() async throws {
            let session = StorageStubURLProtocol.session(host: host) { request in
                if request.httpMethod == "POST" { return .json(#"{"message":"CREATE SCHEMA required"}"#, status: 403) }
                return .json(#"{"catalogs":[],"next_page_token":"repeated"}"#)
            }
            defer { session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let client = try DatabricksUnityCatalogClient(
                host: #require(URL(string: "https://\(host)")), session: session,
                authorization: ProviderStorageAuthorization(accessToken: "fixed", validate: {})
            )
            await #expect(throws: ProviderStorageError.requestFailed(statusCode: 403, message: "CREATE SCHEMA required")) {
                try await client.createSchema(named: "new", in: "main")
            }
            await #expect(throws: ProviderStorageError.invalidResponse) { try await client.catalogs() }
        }
    }
#endif
