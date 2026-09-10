#if canImport(Testing)
    import CryptoKit
    import DahliaRuntimeSupport
    import DahliaServerAPI
    import Foundation
    import HTTPTypes
    import OpenAPIRuntime
    import Synchronization
    import Testing
    @testable import Dahlia

    struct SyncAPIMiddlewareTests {
        @Test(arguments: ["meeting", "screenshot"])
        func textSearchUsesBodyKindAndRoundTripsCursor(kind: String) async throws {
            let vaultID = "019f0d36-0520-7000-8000-000000000001"
            let rowID = "019f0d36-0520-7000-8000-000000000002"
            let origin = try #require(URL(string: "https://example.com"))
            let url = try #require(URL(string: "/api/v1/vaults/\(vaultID)/text-search", relativeTo: origin))
            let cursor = String(decoding: try JSONSerialization.data(withJSONObject: [vaultID, kind, "needle", 1, 1]), as: UTF8.self)
            let publicCursor = try #require(PublicIDWire.cursor(cursor, kind: "textSearch", direction: .encode) as? String)
            let publicRowID = TypeID.encode(try #require(UUID(uuidString: rowID)), as: kind == "screenshot" ? .attachment : .meeting)
            let requestData = try JSONSerialization.data(withJSONObject: ["kind": kind, "query": "needle", "cursor": cursor])
            let responseData = try JSONSerialization.data(withJSONObject: [
                "items": [["id": publicRowID, "meetingId": TypeID.encode(try #require(UUID(uuidString: rowID)), as: .meeting)]],
                "nextCursor": publicCursor,
            ])
            let capture = SyncJSONResponse()
            let middleware = SyncAPIMiddleware(token: "test", maximumBytes: nil, preservingJSONBody: nil, capture: capture)
            _ = try await middleware.intercept(
                HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: url.path),
                body: HTTPBody(requestData), baseURL: origin, operationID: "textSearch"
            ) { _, body, _ in
                let bytes = try await Data(collecting: #require(body), upTo: 16384)
                let request = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
                #expect(request["cursor"] == publicCursor)
                #expect(request["kind"] == kind)
                return (HTTPResponse(status: .ok), HTTPBody(responseData))
            }
            let decoded = try #require(capture.value.withLock { $0 })
            let page = try #require(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
            #expect((page["items"] as? [[String: String]])?.first?["id"] == rowID)
            #expect(page["nextCursor"] as? String == cursor)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestData
            #expect(try PublicIDWire.response(responseData, request: request) == decoded)
        }

        @Test
        func convertsPublicResponseIDsWithoutAnExplicitContentType() async throws {
            let id = "019f0d36-0520-7000-8000-000000000001"
            let capture = SyncJSONResponse()
            let middleware = SyncAPIMiddleware(token: "test", maximumBytes: nil, preservingJSONBody: nil, capture: capture)
            let bytes = try PublicIDWire.data(Data("{\"vaultId\":\"\(id)\"}".utf8), shape: "vault", direction: .encode)
            _ = try await middleware.intercept(
                HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/api/v1/vaults/\(id)"),
                body: nil, baseURL: #require(URL(string: "https://example.com")), operationID: "getVault"
            ) { request, _, _ in
                #expect(request.path?.contains("/vlt_") == true)
                return (HTTPResponse(status: .ok), HTTPBody(bytes))
            }
            let data = try #require(capture.value.withLock { $0 })
            #expect(try JSONSerialization.jsonObject(with: data) as? [String: String] == ["vaultId": id])
        }

        @Test
        func preservesPlainTextAuthorizationErrors() async throws {
            let middleware = SyncAPIMiddleware(token: "test", maximumBytes: nil, preservingJSONBody: nil, capture: nil)
            let bytes = Data("forbidden".utf8)
            do {
                _ = try await middleware.intercept(
                    HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/api/v1/transactions"),
                    body: nil, baseURL: #require(URL(string: "https://example.com")), operationID: "commitTransaction"
                ) { _, _, _ in (HTTPResponse(status: .forbidden), HTTPBody(bytes)) }
                Issue.record("Expected authorization failure")
            } catch let error as SyncHTTPError {
                #expect(error.body == bytes)
                #expect(error.blockedReason == .authorization)
            }
        }

        @Test(arguments: [false, true])
        func sharedNullableDTOsPreserveRecordsAndTombstones(deleted: Bool) throws {
            let id = "019f0d36-0520-7000-8000-000000000001"
            let record = deleted ? "null" : """
            {"vaultId":"\(id)","name":"Vault","revision":1,"createdAt":"2026-09-09T00:00:00Z","updatedAt":"2026-09-09T00:00:00Z"}
            """
            let expected = deleted ? nil : id
            let canonical = try SyncJSON.decoder.decode(Components.Schemas.CanonicalRecord.self, from: Data("""
            {"entity":"vault","id":"\(id)","revision":1,"record":\(record)}
            """.utf8))
            #expect(try #require(canonical.value1).record?.vaultId == expected)
            let conflict = try SyncJSON.decoder.decode(Components.Schemas.RevisionConflict.self, from: Data("""
            {"entity":"vault","id":"\(id)","clientBaseRevision":0,"serverRevision":1,"record":\(record)}
            """.utf8))
            #expect(try #require(conflict.value1).record?.vaultId == expected)
            let changes = try SyncJSON.decoder.decode(Components.Schemas.Changes.self, from: Data("""
            {"items":[{"sequence":1,"vaultId":"\(id)","entity":"vault","entityId":"\(id)","action":"upsert","revision":1,
            "transactionId":"\(id)","record":\(record)}],"cursor":"1","highWaterCursor":"1","hasMore":false}
            """.utf8))
            #expect(try #require(changes.items.first?.value1).record?.vaultId == expected)
        }

        @Test
        func refreshesAuthenticationOnceAndRecreatesTheOperation() async throws {
            let refreshes = Mutex<[Bool]>([])
            let attempts = Mutex(0)
            let api = SyncAPIClient(session: URLSession(configuration: .ephemeral), tokenProvider: { _, refresh in
                refreshes.withLock { $0.append(refresh) }
                return "test"
            })
            let result = try await api.perform(origin: #require(URL(string: "https://example.com")), connectionId: UUID()) { _ in
                let attempt = attempts.withLock { $0 += 1
                    return $0
                }
                if attempt == 1 { throw SyncHTTPError(status: 401, body: Data()) }
                return attempt
            }
            #expect(result == 2)
            #expect(refreshes.withLock { $0 } == [false, true])
            await #expect(throws: SyncHTTPError.self) {
                try await api.perform(origin: #require(URL(string: "https://example.com")), connectionId: UUID()) { _ in
                    throw SyncHTTPError(status: 401, body: Data())
                }
            }
            #expect(refreshes.withLock { $0 } == [false, true, false, true])
        }

        @Test
        func preservesLargeConflictBodies() async throws {
            let document = String(repeating: "a", count: 1024 * 1024)
            let body = Data("{\"code\":\"revision_conflict\",\"conflicts\":[{\"document\":\"\(document)\"}]}".utf8)
            let middleware = SyncAPIMiddleware(token: "test", maximumBytes: nil, preservingJSONBody: nil, capture: nil)
            do {
                _ = try await middleware.intercept(
                    HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/v1/transactions"),
                    body: nil,
                    baseURL: #require(URL(string: "https://example.com")),
                    operationID: "commitTransaction"
                ) { _, _, _ in
                    (HTTPResponse(status: .conflict), HTTPBody(body))
                }
                Issue.record("Conflict response was accepted")
            } catch {
                let failure = try #require(error as? SyncHTTPError)
                #expect(failure.status == 409)
                #expect(failure.blockedReason == .conflict)
                #expect(failure.code == "revision_conflict")
                #expect(failure.body == body)
            }
        }

        @Test(arguments: [false, true])
        func boundsKnownAndStreamedResponseBodies(knownLength: Bool) async throws {
            let middleware = SyncAPIMiddleware(token: "test", maximumBytes: 3, preservingJSONBody: nil, capture: nil)
            do {
                _ = try await middleware.intercept(
                    HTTPRequest(method: .get, scheme: "https", authority: "example.com", path: "/"),
                    body: nil,
                    baseURL: #require(URL(string: "https://example.com")),
                    operationID: "test"
                ) { request, _, _ in
                    #expect(request.headerFields[.authorization] == "Bearer test")
                    let chunks = AsyncStream<ArraySlice<UInt8>> { continuation in
                        continuation.yield([1, 2][...])
                        continuation.yield([3, 4][...])
                        continuation.finish()
                    }
                    return (HTTPResponse(status: .ok), HTTPBody(chunks, length: knownLength ? .known(4) : .unknown, iterationBehavior: .single))
                }
                Issue.record("Oversized response was accepted")
            } catch {
                #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
            }
        }
    }

    struct OpenAPIIntegrationTests {
        @Test(.enabled(
            if: ProcessInfo.processInfo.environment["DAHLIA_OPENAPI_TEST_URL"] != nil,
            "Run with the disposable tests/openapi-fixture.ts server"
        ))
        func generatedClientPreservesNullsDatesReceiptsAndStreamedBytes() async throws {
            let origin = try #require(ProcessInfo.processInfo.environment["DAHLIA_OPENAPI_TEST_URL"].flatMap(URL.init(string:)))
            #expect(origin.host == "127.0.0.1")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = ["X-Forwarded-Email": "swift-test@example.com", "X-Forwarded-User": "swift-test"]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let connectionID = UUID.v7(), vaultID = UUID.v7().uuidString.lowercased(), meetingID = UUID.v7().uuidString.lowercased()
            let data = Data("""
            {"schemaVersion":2,"id":"\(UUID.v7().uuidString
                .lowercased())","vaultId":"\(vaultID)","createdAt":"2026-09-09T00:00:00.001Z","operations":[
            {"id":"\(UUID.v7().uuidString
                .lowercased(
                ))","entity":"vault","action":"create","entityId":"\(
                vaultID
            )","baseRevision":null,"data":{"name":"Swift integration","createdAt":"2026-09-09T00:00:00.001Z"}},
            {"id":"\(UUID.v7().uuidString
                .lowercased(
                ))","entity":"meeting","action":"create","entityId":"\(
                meetingID
            )","baseRevision":null,"data":{"name":"Meeting","description":"","projectId":null,"status":"READY","duration":null,"recordingStartedAt":null,"createdAt":"2026-09-09T00:00:00.001Z","updatedAt":"2026-09-09T00:00:00.001Z"}}]}
            """.utf8)
            let transaction = try SyncJSON.decoder.decode(Components.Schemas.Transaction.self, from: data)
            let first = try await api.data(origin: origin, connectionId: connectionID, preservingJSONBody: data) {
                try await $0.commitTransaction(body: .json(transaction)).ok.body.json
            }
            let replay = try await api.data(origin: origin, connectionId: connectionID, preservingJSONBody: data) {
                try await $0.resolveTransaction(body: .json(transaction)).ok.body.json
            }
            #expect(first == replay)
            #expect(String(decoding: first, as: UTF8.self).contains("\"projectId\":null"))
            let meeting = try await api.perform(origin: origin, connectionId: connectionID) {
                try await $0.getMeeting(path: .init(meetingId: meetingID)).ok.body.json
            }
            #expect(meeting.meetingId == meetingID)
            #expect(meeting.projectId == nil)
            #expect(try SyncAPIDateTranscoder().encode(meeting.createdAt) == "2026-09-09T00:00:00.001Z")
            let fileID = UUID.v7().uuidString.lowercased()
            _ = try await api.perform(origin: origin, connectionId: connectionID) {
                try await $0.reserveFileUpload(body: .json(.init(
                    id: fileID,
                    vaultId: vaultID,
                    name: "bytes.bin",
                    contentType: "application/octet-stream",
                    metadata: .init(source: .upload)
                ))).created
                    .body.json
            }
            let bytes = Data((0 ..< 131_072).map { UInt8($0 % 251) })
            let uploaded = try await api.perform(origin: origin, connectionId: connectionID) { client in
                let chunks = AsyncStream<ArraySlice<UInt8>> { continuation in
                    for offset in stride(from: 0, to: bytes.count, by: 4096) {
                        continuation.yield(Array(bytes[offset ..< min(offset + 4096, bytes.count)])[...])
                    }
                    continuation.finish()
                }
                return try await client.putFileContent(
                    path: .init(fileId: fileID),
                    headers: .init(contentLength: String(bytes.count)),
                    body: .binary(HTTPBody(
                        chunks,
                        length: .known(Int64(bytes.count)),
                        iterationBehavior: .single
                    ))
                ).created.body.json
            }
            let checksum = "SHA-256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(uploaded.checksum == checksum)
            #expect(uploaded.size == bytes.count)
            let commit = Data("""
            {"schemaVersion":2,"id":"\(UUID.v7().uuidString.lowercased())","vaultId":"\(vaultID)","createdAt":"2026-09-09T00:00:00Z","operations":[
            {"id":"\(UUID.v7().uuidString
                .lowercased(
                ))","entity":"file","action":"upsert","entityId":"\(fileID)","baseRevision":null,"data":{"checksum":"\(checksum)","metadata":{}}}]}
            """.utf8)
            let fileTransaction = try SyncJSON.decoder.decode(Components.Schemas.Transaction.self, from: commit)
            _ = try await api.perform(origin: origin, connectionId: connectionID, preservingJSONBody: commit) {
                try await $0.commitTransaction(body: .json(fileTransaction)).ok.body.json
            }
            let body = try await api.perform(origin: origin, connectionId: connectionID) {
                try await $0.getFileContent(path: .init(fileId: fileID)).ok.body.any
            }
            #expect(try await Data(collecting: body, upTo: bytes.count) == bytes)
            // A fresh connection receives an invalidation even after a previous stream disconnects.
            for _ in 0 ..< 2 {
                let streamingSession = URLSession(configuration: configuration)
                defer { streamingSession.invalidateAndCancel() }
                let streamingAPI = SyncAPIClient(session: streamingSession, tokenProvider: { _, _ in "test" })
                let events = try await streamingAPI.perform(origin: origin, connectionId: connectionID) {
                    try await $0.getEvents().ok.body.textEventStream
                }
                var iterator = events.asDecodedServerSentEvents().makeAsyncIterator()
                let firstEvent = try #require(try await iterator.next())
                #expect(firstEvent.event == "invalidation")
                #expect(firstEvent.id != nil)
            }
        }
    }
#endif
