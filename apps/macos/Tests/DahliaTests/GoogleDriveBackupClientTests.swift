import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct GoogleDriveBackupClientTests {
        @Test(arguments: [false, true])
        func listsExactMyDrivePathWithPaginationAndReadOnlyRequests(proxy: Bool) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let session = GoogleSession(
                account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                accessToken: "test-token", grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: URL(string: proxy ? "https://workspace.example/api/2.0/unity-catalog/connections/system_ai_agent_google_drive/proxy/" :
                    "https://www.googleapis.com/")!
            )
            let files = try await GoogleDriveBackupClient(urlSession: transport).listBackups(session: session)
            #expect(files.map(\.id) == ["second", "first"])
        }

        @Test(arguments: ["missing", "duplicate", "proxyError"])
        func missingAmbiguousAndUnauthorizedFolders(mode: String) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let session = try GoogleSession(
                account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                accessToken: mode, grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: #require(URL(string: "https://workspace.example/proxy/"))
            )
            let client = GoogleDriveBackupClient(urlSession: transport)
            switch mode {
            case "missing": #expect(try await client.listBackups(session: session).isEmpty)
            case "duplicate":
                await #expect(throws: GoogleDriveBackupError.ambiguousFolder) { try await client.listBackups(session: session) }
            default:
                await #expect(throws: (any Error).self) { try await client.listBackups(session: session) }
            }
        }

        @Test
        func googleCredentialFailureRequiresReauthenticationAcrossDriveReads() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let session = try GoogleSession(
                account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                accessToken: "google401", grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: #require(URL(string: "https://workspace.example/proxy/"))
            )
            let client = GoogleDriveBackupClient(urlSession: transport)
            let listError = await #expect(throws: GoogleCalendarAPIError.self) { try await client.listBackups(session: session) }
            #expect(listError?.errorDescription == L10n.googleDatabricksReauthenticationRequired)
            let file = GoogleDriveBackupFile(id: "backup", name: "backup.tar.gz", size: nil, modifiedTime: nil)
            let downloadError = await #expect(throws: GoogleCalendarAPIError.self) { try await client.download(file, session: session) }
            #expect(downloadError?.errorDescription == L10n.googleDatabricksReauthenticationRequired)
        }

        @Test(arguments: [200, 403])
        func downloadPreservesProxyAuthenticationErrors(status: Int) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let session = try GoogleSession(
                account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                accessToken: "download-proxy-error-\(status)", grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: #require(URL(string: "https://workspace.example/proxy/"))
            )
            let file = GoogleDriveBackupFile(id: "backup", name: "backup.tar.gz", size: nil, modifiedTime: nil)
            let error = await #expect(throws: GoogleCalendarAPIError.self) {
                try await GoogleDriveBackupClient(urlSession: transport).download(file, session: session)
            }
            guard case let .proxyError(code, message) = error else {
                Issue.record("Expected the proxy authentication error, got \(String(describing: error))")
                return
            }
            #expect(code == "UNAUTHENTICATED")
            #expect(message == "Please login")
        }

        @Test(arguments: [false, true])
        func downloadKeepsBinaryContents(proxy: Bool) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let session = GoogleSession(
                account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                accessToken: "download-binary", grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: URL(string: proxy ? "https://workspace.example/proxy/" : "https://www.googleapis.com/")!
            )
            let file = GoogleDriveBackupFile(id: "backup", name: "backup.tar.gz", size: nil, modifiedTime: nil)
            let download = try await GoogleDriveBackupClient(urlSession: transport).download(file, session: session)
            defer { try? FileManager.default.removeItem(at: download) }
            #expect(try Data(contentsOf: download) == DriveBackupURLProtocol.binaryPayload)
        }

        @Test
        @MainActor
        func directDriveScopeAndProxyAreSeparateFromCalendar() {
            #expect(GoogleOAuthScope.drive == ["https://www.googleapis.com/auth/drive.readonly"])
            #expect(GoogleAuthSessionKind.drive.keychainKey != GoogleAuthSessionKind.calendar.keychainKey)
            #expect(GoogleAuthSessionKind.drive.sessionDidChangeNotification != GoogleAuthSessionKind.calendar.sessionDidChangeNotification)
            #expect(DatabricksProxyGoogleSignInProvider.driveConnectionName == "system_ai_agent_google_drive")
        }
    }

    final class DriveBackupURLProtocol: URLProtocol, @unchecked Sendable {
        static let binaryPayload = Data([0x1F, 0x8B]) + Data(repeating: 0xA5, count: 128 * 1024)
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let query = items.first { $0.name == "q" }?.value ?? ""
            #expect(request.httpMethod == "GET")
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer google401" {
                let body = #"{"error":{"code":401,"message":"Invalid Credentials","status":"UNAUTHENTICATED"}}"#
                client?.urlProtocol(
                    self, didReceive: HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if items.first(where: { $0.name == "alt" })?.value == "media" {
                #expect(url.path.hasSuffix("/drive/v3/files/backup"))
                let isError = authorization?.hasPrefix("Bearer download-proxy-error-") == true
                let status = authorization == "Bearer download-proxy-error-403" ? 403 : 200
                let error = #"{"jsonrpc":"2.0","error":{"message":"{\"error_code\":\"UNAUTHENTICATED\",\"message\":\"Please login\"}"}}"#
                client?.urlProtocol(
                    self,
                    didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: isError ? Data(error.utf8) : Self.binaryPayload)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            #expect(url.path.hasSuffix("/drive/v3/files"))
            #expect(query.contains("trashed = false"))
            #expect(items.first { $0.name == "corpora" }?.value == "user")
            let body: String
            if authorization == "Bearer missing" {
                body = #"{"files":[]}"#
            } else if authorization == "Bearer duplicate" {
                body = #"{"files":[{"id":"one","name":"Dahlia"},{"id":"two","name":"Dahlia"}]}"#
            } else if authorization == "Bearer proxyError" {
                body = #"{"jsonrpc":"2.0","error":{"message":"{\"error_code\":\"UNAUTHENTICATED\",\"message\":\"Please login\"}"}}"#
            } else if query.contains("'root' in parents and name = 'Dahlia'") {
                body = #"{"files":[{"id":"dahliaFolder","name":"Dahlia"}]}"#
            } else if query.contains("'dahliaFolder' in parents and name = 'Backup'") {
                body = #"{"files":[{"id":"backupFolder","name":"Backup"}]}"#
            } else {
                #expect(query.contains("'backupFolder' in parents"))
                if items.first(where: { $0.name == "pageToken" })?.value == "next" {
                    body = #"{"files":[{"id":"second","name":"second.tar.gz","modifiedTime":"2026-11-13T12:00:00Z"}]}"#
                } else {
                    body = #"{"files":[{"id":"first","name":"first.tar.gz","modifiedTime":"2026-11-12T12:00:00Z"},{"id":"other","name":"other.txt"}],"nextPageToken":"next"}"#
                }
            }
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
