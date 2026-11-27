import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DatabricksVolumeStorageTests {
        private let host = "volume-\(UUID().uuidString.lowercased()).example"
        private static let volumePath = "/api/2.1/unity-catalog/volumes/main.dahlia.dahlia_storage_42"
        private static let me = StorageStubURLProtocol.Response.json(#"{"id":"42","userName":"me@example.com"}"#)

        private func storage(_ handler: @escaping StorageStubURLProtocol.Handler) -> (DatabricksVolumeStorage, URLSession) {
            let session = StorageStubURLProtocol.session(host: host, handler: handler)
            let storage = DatabricksVolumeStorage(
                host: URL(string: "https://\(host)")!, location: DatabricksStorageLocation("main.dahlia")!, session: session
            ) { "databricks-token" }
            return (storage, session)
        }

        private func finish(_ session: URLSession) {
            session.invalidateAndCancel()
            StorageStubURLProtocol.reset(host: host)
        }

        @Test
        func volumeNamesUseOnlyTheUserIDDigits() throws {
            #expect(try DatabricksVolumeStorage.volumeName(userID: "42") == "dahlia_storage_42")
            #expect(try DatabricksVolumeStorage.volumeName(userID: "42@7001") == "dahlia_storage_42")
            for id in ["", "@1", "abc", "4 2", "42a@1", "４２", "42-1"] {
                #expect(throws: ProviderStorageError.unsupportedUserID) { try DatabricksVolumeStorage.volumeName(userID: id) }
            }
        }

        @Test
        func storageLocationsNameExactlyACatalogAndASchema() {
            #expect(DatabricksStorageLocation(" main.dahlia ")?.description == "main.dahlia")
            #expect(DatabricksStorageLocation("my-catalog.my_schema")?.description == "my-catalog.my_schema")
            for value in ["", "main", "main.", ".dahlia", "a.b.c", "a b.c", "a/b.c", "`a`.b", "a\\b.c"] {
                #expect(DatabricksStorageLocation(value) == nil)
            }
        }

        @Test
        func listingBeforeTheVolumeExistsCreatesNothing() async throws {
            let (storage, session) = storage { request in
                switch request.url!.path {
                case "/api/2.0/preview/scim/v2/Me": Self.me
                case Self.volumePath: .json(#"{"error_code":"RESOURCE_DOES_NOT_EXIST","message":"missing"}"#, status: 404)
                default: StorageStubURLProtocol.Response(status: 500)
                }
            }
            defer { finish(session) }
            #expect(try await storage.list(directory: "backup").isEmpty)
            #expect(StorageStubURLProtocol.requests(host: host).allSatisfy { $0.httpMethod == "GET" })
        }

        @Test(arguments: [false, true])
        func uploadCreatesTheUsersManagedVolumeAndPutsTheFileInBackup(anotherMacCreatesItFirst: Bool) async throws {
            let exists = Mutex(false)
            let (storage, session) = storage { request in
                switch (request.httpMethod, request.url!.path) {
                case ("GET", "/api/2.0/preview/scim/v2/Me"): return Self.me
                case ("GET", Self.volumePath):
                    return exists.withLock { $0 }
                        ? .json(#"{"owner":"Me@Example.com","volume_type":"MANAGED"}"#)
                        : .json(#"{"error_code":"RESOURCE_DOES_NOT_EXIST"}"#, status: 404)
                case ("POST", "/api/2.1/unity-catalog/volumes"):
                    exists.withLock { $0 = true }
                    return anotherMacCreatesItFirst
                        ? .json(#"{"error_code":"RESOURCE_ALREADY_EXISTS"}"#, status: 409)
                        : .json(#"{"owner":"me@example.com","volume_type":"MANAGED"}"#)
                case ("PUT", "/api/2.0/fs/directories/Volumes/main/dahlia/dahlia_storage_42/backup"): return StorageStubURLProtocol.Response()
                case ("PUT", "/api/2.0/fs/files/Volumes/main/dahlia/dahlia_storage_42/backup/Dahlia-x.tar.gz"):
                    return StorageStubURLProtocol.Response(status: 204)
                default: return StorageStubURLProtocol.Response(status: 500)
                }
            }
            defer { finish(session) }
            let file = try temporaryBackupFile(named: "Dahlia-x.tar.gz", contents: "volume")
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

            try await storage.upload(file, to: "backup", name: "Dahlia-x.tar.gz")

            let requests = StorageStubURLProtocol.requests(host: host)
            let create = try #require(requests.first { $0.httpMethod == "POST" })
            #expect(create.jsonBody["catalog_name"] as? String == "main")
            #expect(create.jsonBody["schema_name"] as? String == "dahlia")
            #expect(create.jsonBody["name"] as? String == "dahlia_storage_42")
            #expect(create.jsonBody["volume_type"] as? String == "MANAGED")
            #expect(create.jsonBody["comment"] as? String == "Dahlia storage for me@example.com")
            let put = try #require(requests.last)
            #expect(put.httpMethod == "PUT")
            #expect(put.query("overwrite") == "false")
            #expect(put.httpBody == Data("volume".utf8))
            #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer databricks-token")
        }

        @Test(arguments: [#"{"owner":"someone@example.com","volume_type":"MANAGED"}"#, #"{"owner":"me@example.com","volume_type":"EXTERNAL"}"#])
        func aVolumeTheUserDoesNotOwnAsManagedIsNeverUsed(volume: String) async throws {
            let (storage, session) = storage { request in
                switch request.url!.path {
                case "/api/2.0/preview/scim/v2/Me": Self.me
                case Self.volumePath: .json(volume)
                default: StorageStubURLProtocol.Response()
                }
            }
            defer { finish(session) }
            let owner = volume.contains("someone") ? "someone@example.com" : "me@example.com"
            let expected = ProviderStorageError.volumeNotOwned(volume: "main.dahlia.dahlia_storage_42", owner: owner)
            await #expect(throws: expected) { try await storage.list(directory: "backup") }
            let file = try temporaryBackupFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: expected) { try await storage.upload(file, to: "backup", name: file.lastPathComponent) }
            let stray = ProviderStorageFile(id: "/Volumes/main/dahlia/dahlia_storage_42/backup/x", name: "x", size: nil, modifiedAt: nil)
            await #expect(throws: expected) { try await storage.delete(stray) }
            #expect(!StorageStubURLProtocol.requests(host: host).contains { $0.url!.path.contains("/fs/") })
        }

        @Test
        func listingReadsTheBackupFolderAndOperationsStayInsideTheVolume() async throws {
            let directory = "/api/2.0/fs/directories/Volumes/main/dahlia/dahlia_storage_42/backup"
            let (storage, session) = storage { request in
                switch (request.httpMethod, request.url!.path) {
                case (_, "/api/2.0/preview/scim/v2/Me"): Self.me
                case (_, Self.volumePath): .json(#"{"owner":"me@example.com","volume_type":"MANAGED"}"#)
                case ("GET", directory) where request.query("page_token") == nil:
                    .json(#"""
                    {"contents":[{"path":"/Volumes/main/dahlia/dahlia_storage_42/backup/old","is_directory":true},
                    {"path":"/Volumes/main/dahlia/dahlia_storage_42/backup/Dahlia-a.tar.gz","is_directory":false,"file_size":5,"last_modified":1700000000000}],
                    "next_page_token":"two"}
                    """#)
                case ("GET", directory):
                    .json(
                        #"{"contents":[{"path":"/Volumes/main/dahlia/dahlia_storage_42/backup/Dahlia-b.tar.gz","file_size":6,"last_modified":1800000000000}]}"#
                    )
                case ("GET", "/api/2.0/fs/files/Volumes/main/dahlia/dahlia_storage_42/backup/Dahlia-a.tar.gz"):
                    StorageStubURLProtocol.Response(body: Data("A".utf8))
                case ("DELETE", "/api/2.0/fs/files/Volumes/main/dahlia/dahlia_storage_42/backup/Dahlia-b.tar.gz"):
                    StorageStubURLProtocol.Response(status: 204)
                default: StorageStubURLProtocol.Response(status: 500)
                }
            }
            defer { finish(session) }
            let files = try await storage.list(directory: "backup")
            #expect(files.map(\.name) == ["Dahlia-b.tar.gz", "Dahlia-a.tar.gz"])
            #expect(files.map(\.size) == [6, 5])
            let downloaded = try await storage.download(files[1])
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try Data(contentsOf: downloaded) == Data("A".utf8))
            try await storage.delete(files[0])
            #expect(StorageStubURLProtocol.requests(host: host).last?.httpMethod == "DELETE")
            for id in ["/Volumes/main/dahlia/other/backup/x", "/Volumes/main/dahlia/dahlia_storage_42/backup/../../other/x"] {
                await #expect(throws: ProviderStorageError.invalidResponse) {
                    try await storage.delete(ProviderStorageFile(id: id, name: "x", size: nil, modifiedAt: nil))
                }
            }
            #expect(StorageStubURLProtocol.requests(host: host).filter { $0.httpMethod == "DELETE" }.count == 1)
        }

        @Test
        func backupsOverTheSingleUploadLimitAreRefusedBeforeAnyRequest() async throws {
            let (storage, session) = storage { _ in StorageStubURLProtocol.Response() }
            defer { finish(session) }
            let file = try temporaryBackupFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            // A sparse file has the logical size without writing 5000 MiB.
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(DatabricksVolumeStorage.uploadLimit) + 1)
            try handle.close()
            await #expect(throws: ProviderStorageError.fileTooLarge) { try await storage.upload(file, to: "backup", name: file.lastPathComponent) }
            #expect(StorageStubURLProtocol.requests(host: host).isEmpty)
        }
    }
#endif
