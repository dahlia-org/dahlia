import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct GoogleDriveAPIClientTests {
        @Test
        func validatesStoredExportFolderByID() async throws {
            let recorder = GoogleDriveRequestRecorder(responses: [
                .init(data: Data(#"{"mimeType":"application/vnd.google-apps.folder","trashed":false}"#.utf8)),
            ])
            let client = GoogleDriveAPIClient(session: makeGoogleDriveRecordingSession(recorder: recorder))

            let isAvailable = try await client.isExportFolderAvailable(
                accessToken: "access-token",
                folderID: "folder-1"
            )

            #expect(isAvailable)
            #expect(recorder.requests.count == 1)
            #expect(recorder.requests[0].url?.path == "/drive/v3/files/folder-1")
        }

        @Test
        func unavailableStoredExportFolderReturnsFalse() async throws {
            let recorder = GoogleDriveRequestRecorder(responses: [
                .init(statusCode: 404, data: Data(#"{"error":{"message":"Not found"}}"#.utf8)),
            ])
            let client = GoogleDriveAPIClient(session: makeGoogleDriveRecordingSession(recorder: recorder))

            let isAvailable = try await client.isExportFolderAvailable(
                accessToken: "access-token",
                folderID: "missing-folder"
            )

            #expect(!isAvailable)
        }

        @Test
        func createsGoogleDocumentWithResumableRTFUpload() async throws {
            let recorder = GoogleDriveRequestRecorder()
            let session = makeGoogleDriveRecordingSession(recorder: recorder)
            let client = GoogleDriveAPIClient(session: session)
            let rtfData = Data(#"{\rtf1 Summary}"#.utf8)

            let fileID = try await client.upsertGoogleDocument(
                accessToken: "access-token",
                fileName: "Weekly / Sync.rtf",
                data: rtfData,
                dataMimeType: "application/rtf",
                appProperties: [
                    "dahliaKind": "summary",
                    "dahliaMeetingId": "meeting-1",
                ],
                parentFolderID: "folder-1"
            )

            #expect(fileID == "document-1")
            let requests = recorder.requests
            #expect(requests.count == 3)

            let searchRequest = requests[0]
            #expect(searchRequest.httpMethod == "GET")
            let searchURL = try #require(searchRequest.url)
            let searchQuery = try #require(
                URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "q" })?
                    .value
            )
            #expect(searchQuery.contains("dahliaMeetingId"))
            #expect(!searchQuery.contains("parents"))
            let searchQueryItems = try Dictionary(
                uniqueKeysWithValues: #require(
                    URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems
                ).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            #expect(searchQueryItems["corpora"] == "allDrives")
            #expect(searchQueryItems["includeItemsFromAllDrives"] == "true")
            #expect(searchQueryItems["supportsAllDrives"] == "true")

            let metadataRequest = requests[1]
            #expect(metadataRequest.httpMethod == "POST")
            #expect(metadataRequest.value(forHTTPHeaderField: "X-Upload-Content-Type") == "application/rtf")
            #expect(metadataRequest.value(forHTTPHeaderField: "X-Upload-Content-Length") == String(rtfData.count))
            let metadata = try JSONSerialization.jsonObject(with: #require(metadataRequest.httpBody)) as? [String: Any]
            #expect(metadata?["name"] as? String == "Weekly / Sync")
            #expect(metadata?["mimeType"] as? String == "application/vnd.google-apps.document")
            #expect(metadata?["parents"] as? [String] == ["folder-1"])

            let uploadRequest = requests[2]
            #expect(uploadRequest.httpMethod == "PUT")
            #expect(uploadRequest.url?.absoluteString == "https://upload.example.com/session-1")
            #expect(uploadRequest.httpBody == rtfData)
        }

        @Test
        func createsConfiguredExportFolderInMyDriveWhenMissing() async throws {
            let recorder = GoogleDriveRequestRecorder(responses: [
                .init(data: Data(#"{"files":[]}"#.utf8)),
                .init(data: Data(#"{"id":"folder-1"}"#.utf8)),
            ])
            let client = GoogleDriveAPIClient(session: makeGoogleDriveRecordingSession(recorder: recorder))

            let folderID = try await client.resolveExportFolderID(
                accessToken: "access-token",
                folderName: "Meeting Notes"
            )

            #expect(folderID == "folder-1")
            let requests = recorder.requests
            #expect(requests.count == 2)

            let searchURL = try #require(requests[0].url)
            let searchQuery = try #require(
                URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "q" })?
                    .value
            )
            #expect(searchQuery.contains("name = 'Meeting Notes'"))
            #expect(searchQuery.contains("'root' in parents"))
            #expect(searchQuery.contains("dahliaKind"))

            let createRequest = requests[1]
            #expect(createRequest.httpMethod == "POST")
            let metadata = try JSONSerialization.jsonObject(with: #require(createRequest.httpBody)) as? [String: Any]
            #expect(metadata?["name"] as? String == "Meeting Notes")
            #expect(metadata?["mimeType"] as? String == "application/vnd.google-apps.folder")
            #expect(metadata?["parents"] as? [String] == ["root"])
        }

        @Test
        func reusesExistingConfiguredExportFolder() async throws {
            let recorder = GoogleDriveRequestRecorder(responses: [
                .init(data: Data(#"{"files":[{"id":"folder-1","parents":["root"]}]}"#.utf8)),
            ])
            let client = GoogleDriveAPIClient(session: makeGoogleDriveRecordingSession(recorder: recorder))

            let folderID = try await client.resolveExportFolderID(
                accessToken: "access-token",
                folderName: "Meeting Notes"
            )

            #expect(folderID == "folder-1")
            #expect(recorder.requests.count == 1)
        }

        @Test
        func movesExistingDocumentToConfiguredFolder() async throws {
            let recorder = GoogleDriveRequestRecorder(responses: [
                .init(data: Data(#"{"files":[{"id":"document-1","parents":["old-folder"]}]}"#.utf8)),
                .init(
                    headers: ["Location": "https://upload.example.com/session-1"],
                    data: Data()
                ),
                .init(data: Data(#"{"id":"document-1"}"#.utf8)),
            ])
            let client = GoogleDriveAPIClient(session: makeGoogleDriveRecordingSession(recorder: recorder))

            _ = try await client.upsertGoogleDocument(
                accessToken: "access-token",
                fileName: "Weekly Sync.rtf",
                data: Data(#"{\rtf1 Summary}"#.utf8),
                dataMimeType: "application/rtf",
                appProperties: ["dahliaMeetingId": "meeting-1"],
                parentFolderID: "new-folder"
            )

            let metadataRequest = recorder.requests[1]
            #expect(metadataRequest.httpMethod == "PATCH")
            let metadataURL = try #require(metadataRequest.url)
            let queryItems = try #require(
                URLComponents(url: metadataURL, resolvingAgainstBaseURL: false)?.queryItems
            )
            #expect(queryItems.first(where: { $0.name == "addParents" })?.value == "new-folder")
            #expect(queryItems.first(where: { $0.name == "removeParents" })?.value == "old-folder")
        }
    }

    private struct GoogleDriveStubResponse: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            data: Data
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
        }
    }

    private final class GoogleDriveRequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequests: [URLRequest] = []
        private let responses: [GoogleDriveStubResponse]

        init(responses: [GoogleDriveStubResponse] = [
            .init(data: Data(#"{"files":[]}"#.utf8)),
            .init(
                headers: ["Location": "https://upload.example.com/session-1"],
                data: Data()
            ),
            .init(data: Data(#"{"id":"document-1"}"#.utf8)),
        ]) {
            self.responses = responses
        }

        var requests: [URLRequest] {
            lock.withLock { storedRequests }
        }

        func record(_ request: URLRequest) -> Int {
            var recordedRequest = request
            if recordedRequest.httpBody == nil,
               let bodyStream = request.httpBodyStream {
                recordedRequest.httpBody = Self.read(bodyStream)
            }
            return lock.withLock {
                storedRequests.append(recordedRequest)
                return storedRequests.count
            }
        }

        func response(at requestIndex: Int) -> GoogleDriveStubResponse {
            guard responses.indices.contains(requestIndex - 1) else {
                return .init(statusCode: 500, data: Data(#"{"error":{"message":"Missing stub response"}}"#.utf8))
            }
            return responses[requestIndex - 1]
        }

        private static func read(_ stream: InputStream) -> Data {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            stream.open()
            defer { stream.close() }

            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private func makeGoogleDriveRecordingSession(recorder: GoogleDriveRequestRecorder) -> URLSession {
        GoogleDriveRecordingURLProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleDriveRecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class GoogleDriveRecordingURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var recorder: GoogleDriveRequestRecorder?

        // swiftlint:disable:next static_over_final_class
        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        // swiftlint:disable:next static_over_final_class
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let recorder = Self.recorder else {
                fatalError("GoogleDriveRecordingURLProtocol recorder is not configured")
            }
            let requestIndex = recorder.record(request)
            let stub = recorder.response(at: requestIndex)
            let response = makeResponse(statusCode: stub.statusCode, headers: stub.headers)

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private func makeResponse(statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: nil,
                      headerFields: headers
                  ) else {
                fatalError("Could not create test HTTP response")
            }
            return response
        }
    }
#endif
