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
        @MainActor
        func directDriveScopeAndProxyAreSeparateFromCalendar() {
            #expect(GoogleOAuthScope.drive == ["https://www.googleapis.com/auth/drive.readonly"])
            #expect(GoogleAuthSessionKind.drive.keychainKey != GoogleAuthSessionKind.calendar.keychainKey)
            #expect(GoogleAuthSessionKind.drive.sessionDidChangeNotification != GoogleAuthSessionKind.calendar.sessionDidChangeNotification)
            #expect(DatabricksProxyGoogleSignInProvider.driveConnectionName == "system_ai_agent_google_drive")
        }
    }

    final class DriveBackupURLProtocol: URLProtocol, @unchecked Sendable {
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let query = items.first { $0.name == "q" }?.value ?? ""
            #expect(request.httpMethod == "GET")
            let authorization = request.value(forHTTPHeaderField: "Authorization")
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
