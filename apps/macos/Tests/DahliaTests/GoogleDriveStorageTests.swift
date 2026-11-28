import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct GoogleDriveStorageTests {
        private let host = "drive-\(UUID().uuidString.lowercased()).example"

        private func storage(_ handler: @escaping StorageStubURLProtocol.Handler) -> (GoogleDriveStorage, URLSession) {
            let session = StorageStubURLProtocol.session(host: host, handler: handler)
            let storage = GoogleDriveStorage(baseURL: URL(string: "https://\(host)/")!, session: session) { "drive-token" }
            return (storage, session)
        }

        private static func files(_ entries: [(id: String, name: String)]) -> StorageStubURLProtocol.Response {
            let items = entries.map { #"{"id":"\#($0.id)","name":"\#($0.name)","size":"7","modifiedTime":"2026-11-27T01:02:03.456Z"}"# }
            return .json(#"{"files":[\#(items.joined(separator: ","))]}"#)
        }

        @Test
        func listingBeforeTheFoldersExistReturnsNothingAndCreatesNothing() async throws {
            let (storage, session) = storage { _ in Self.files([]) }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            #expect(try await storage.list(directory: "backup").isEmpty)
            let requests = StorageStubURLProtocol.requests(host: host)
            #expect(requests.map(\.httpMethod) == ["GET"])
            #expect(requests.first?.query("q")?.contains("'root' in parents and name = 'Dahlia'") == true)
            #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer drive-token")
        }

        @Test
        func configuredFolderIsUsedAndItsNameIsEscaped() async throws {
            let session = StorageStubURLProtocol.session(host: host) { _ in Self.files([]) }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let storage = try GoogleDriveStorage(folderName: "Team's files", baseURL: #require(URL(string: "https://\(host)/")), session: session) {
                "token"
            }
            #expect(try await storage.list(directory: "backup").isEmpty)
            let request = try #require(StorageStubURLProtocol.requests(host: host).first)
            #expect(request.query("q")?.contains(#"name = 'Team\'s files'"#) == true)
        }

        @Test
        func uploadCreatesTheMissingFoldersThenSendsOneResumableSession() async throws {
            let created = Mutex<[String: String]>([:])
            let host = host
            let (storage, session) = storage { request in
                let path = request.url!.path
                switch (request.httpMethod, path) {
                case ("GET", "/drive/v3/files"):
                    let query = request.query("q") ?? ""
                    let folders = created.withLock { $0 }
                    if query.contains("'root' in parents and name = 'Dahlia'"), let id = folders["Dahlia"] { return Self.files([(id, "Dahlia")]) }
                    if query.contains("name = 'backup'"), let id = folders["backup"] { return Self.files([(id, "backup")]) }
                    return Self.files([])
                case ("POST", "/drive/v3/files"):
                    let name = request.jsonBody["name"] as? String ?? ""
                    let id = name == "Dahlia" ? "dahliaFolder" : "backupFolder"
                    created.withLock { $0[name] = id }
                    return .json(#"{"id":"\#(id)"}"#)
                case ("POST", "/upload/drive/v3/files"):
                    return StorageStubURLProtocol.Response(headers: ["Location": "https://\(host)/upload-session/1"])
                case ("PUT", "/upload-session/1"):
                    return .json(#"{"id":"uploaded"}"#)
                default:
                    return StorageStubURLProtocol.Response(status: 404)
                }
            }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let file = try temporaryBackupFile(contents: "twelve bytes")
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

            try await storage.upload(file, to: "backup", name: file.lastPathComponent)

            let requests = StorageStubURLProtocol.requests(host: host)
            let folderCreations = requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/drive/v3/files" }
            #expect(folderCreations.map { $0.jsonBody["name"] as? String } == ["Dahlia", "backup"])
            #expect(folderCreations.map { $0.jsonBody["parents"] as? [String] } == [["root"], ["dahliaFolder"]])
            #expect(folderCreations.allSatisfy { $0.jsonBody["mimeType"] as? String == "application/vnd.google-apps.folder" })
            let start = try #require(requests.first { $0.url?.path == "/upload/drive/v3/files" })
            #expect(start.query("uploadType") == "resumable")
            #expect(start.jsonBody["name"] as? String == file.lastPathComponent)
            #expect(start.jsonBody["parents"] as? [String] == ["backupFolder"])
            #expect(start.value(forHTTPHeaderField: "X-Upload-Content-Length") == "12")
            let put = try #require(requests.first { $0.url?.path == "/upload-session/1" })
            #expect(put.httpMethod == "PUT")
            #expect(put.httpBody == Data("twelve bytes".utf8))
        }

        @Test
        func duplicateFoldersAreAnErrorRatherThanAGuess() async throws {
            let (storage, session) = storage { request in
                request.httpMethod == "GET" ? Self.files([("first", "Dahlia"), ("second", "Dahlia")]) : StorageStubURLProtocol.Response(status: 500)
            }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            await #expect(throws: ProviderStorageError.ambiguousFolder) { try await storage.list(directory: "backup") }
            let file = try temporaryBackupFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: ProviderStorageError.ambiguousFolder) {
                try await storage.upload(file, to: "backup", name: file.lastPathComponent)
            }
            #expect(StorageStubURLProtocol.requests(host: host).allSatisfy { $0.httpMethod == "GET" })
        }

        @Test
        func filesWithTheSameNameAreDownloadedAndTrashedByTheirOwnID() async throws {
            let (storage, session) = storage { request in
                let query = request.query("q") ?? ""
                switch (request.httpMethod, request.url!.path) {
                case ("GET", "/drive/v3/files") where query.contains("name = 'Dahlia'"): return Self.files([("dahliaFolder", "Dahlia")])
                case ("GET", "/drive/v3/files") where query.contains("name = 'backup'"): return Self.files([("backupFolder", "backup")])
                case ("GET", "/drive/v3/files"): return Self.files([("copyA", "Dahlia-same.tar.gz"), ("copyB", "Dahlia-same.tar.gz")])
                case ("GET", "/drive/v3/files/copyB"): return StorageStubURLProtocol.Response(body: Data("B".utf8))
                case ("PATCH", "/drive/v3/files/copyA"): return .json(#"{"id":"copyA"}"#)
                default: return StorageStubURLProtocol.Response(status: 404)
                }
            }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let files = try await storage.list(directory: "backup")
            #expect(files.map(\.id) == ["copyA", "copyB"])
            #expect(files.first?.size == 7)
            #expect(files.first?.modifiedAt != nil)
            let listQuery = StorageStubURLProtocol.requests(host: host).last?.query("q")
            #expect(listQuery == "'backupFolder' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false")

            let downloaded = try await storage.download(files[1])
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Data(contentsOf: downloaded) == Data("B".utf8))
            try await storage.delete(files[0])
            let trash = try #require(StorageStubURLProtocol.requests(host: host).last)
            #expect(trash.httpMethod == "PATCH")
            #expect(trash.url?.path == "/drive/v3/files/copyA")
            #expect(trash.jsonBody["trashed"] as? Bool == true)
            #expect(StorageStubURLProtocol.requests(host: host).contains { $0.url?.path == "/drive/v3/files/copyB" && $0.query("alt") == "media" })
        }

        @Test
        func failuresCarryGooglesMessage() async throws {
            let (storage, session) = storage { _ in .json(#"{"error":{"code":403,"message":"Insufficient Permission"}}"#, status: 403) }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            await #expect(throws: ProviderStorageError.requestFailed(statusCode: 403, message: "Insufficient Permission")) {
                try await storage.list(directory: "backup")
            }
        }

        @Test
        func idsOutsideDrivesAlphabetAreNeverSent() async throws {
            let (storage, session) = storage { _ in StorageStubURLProtocol.Response() }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let file = ProviderStorageFile(id: "../about", name: "x", size: nil, modifiedAt: nil)
            await #expect(throws: ProviderStorageError.invalidResponse) { try await storage.download(file) }
            await #expect(throws: ProviderStorageError.invalidResponse) { try await storage.delete(file) }
            #expect(StorageStubURLProtocol.requests(host: host).isEmpty)
        }
    }
#endif
