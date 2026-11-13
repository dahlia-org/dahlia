import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SearchNeologdCatalogTests {
        @Test
        func latestThreeExcludePrereleasesInvalidDigestsAndOtherFormats() async throws {
            let fixtures = [
                Self.release("6.9.0"), Self.release("6.10.0"), Self.release("6.8.0"), Self.release("6.7.0"),
                Self.release("6.10.0"), Self.release("7.0.0"), Self.release("6.99.0", prerelease: true),
                Self.release("6.98.0", draft: true), Self.release("6.97.0", digest: "sha256:bad"),
                Self.release("6.96.0", digest: nil), Self.release("6.95.0", assetName: "other.zip"),
            ]
            let session = try Self.session(firstPage: fixtures)
            defer { session.invalidateAndCancel() }
            let releases = try await SearchNeologdCatalog.fetch(session: session)
            #expect(releases.map(\.version) == ["6.10.0", "6.9.0", "6.8.0"])
            #expect(releases.first?.downloadURL
                .absoluteString == "https://github.com/lindera/lindera/releases/download/v6.10.0/lindera-ipadic-neologd-6.10.0.zip")
            for name in ["neologd-../../bad-a", "neologd-6.0.0-short", "neologd-6.0.0-beta-" + String(repeating: "a", count: 64)] {
                #expect(SearchNeologdRelease(directoryName: name) == nil)
            }
            for release in SearchNeologdCatalog.fallback {
                #expect(release.isValid)
            }
        }

        @Test
        func followsTheNextPageWhenNewerIncompatibleReleasesFillTheFirst() async throws {
            let session = try Self.session(
                firstPage: (0 ..< 100).map { Self.release("7.0.\($0)") },
                secondPage: [Self.release("6.2.0"), Self.release("6.1.0"), Self.release("6.0.0")]
            )
            defer { session.invalidateAndCancel() }
            #expect(try await SearchNeologdCatalog.fetch(session: session).map(\.version) == ["6.2.0", "6.1.0", "6.0.0"])
        }

        @Test
        func combinesLatestWithInstalledAndRetainsTheCacheAfterNetworkFailure() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "dahlia-neologd-test-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let initial = try await service.snapshot()
            #expect(initial.neologdReleases == SearchNeologdCatalog.fallback)
            let old = SearchNeologdRelease(version: "2.3.4", sha256: String(repeating: "b", count: 64))
            for release in [SearchNeologdCatalog.fallback[0], old] {
                let target = directory.appending(path: release.id)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: target.appending(path: "metadata.json"))
            }
            let session = try Self.session(firstPage: [Self.release("6.9.0"), Self.release("6.8.0"), Self.release("6.7.0")])
            defer { session.invalidateAndCancel() }
            try await service.refreshAvailableReleases(session: session)
            let combined = try await service.snapshot()
            #expect(combined.neologdReleases.map(\.version) == ["6.9.0", "6.8.0", "6.7.0", "6.2.0", "2.3.4"])
            #expect(combined.installedNeologdIDs == [SearchNeologdCatalog.fallback[0].id, old.id])
            #expect(combined.preferred == initial.preferred)
            #expect(combined.active == initial.active)
            let failing = try Self.session(firstPage: [], status: 403)
            defer { failing.invalidateAndCancel() }
            await #expect(throws: SearchDictionaryError.catalogUnavailable) { try await service.refreshAvailableReleases(session: failing) }
            let reopened = SearchDictionaryService(database: database, directory: directory)
            #expect(try await reopened.snapshot().neologdReleases == combined.neologdReleases)
            // Local files still have to pass the real runtime loader before selection is saved.
            await #expect(throws: SearchDictionaryError.invalidDictionary) { try await reopened.selectNeologd(old) }
            #expect(try await reopened.snapshot().preferred == initial.preferred)
        }

        @Test
        func failedOrCancelledDownloadsPreserveTheDraftAndIndex() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "dahlia-neologd-test-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try AppDatabaseManager(path: ":memory:")
            let service = SearchDictionaryService(database: database, directory: directory)
            let initial = try await service.snapshot()
            let before = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            }
            let session = try Self.session(firstPage: [])
            defer { session.invalidateAndCancel() }
            await #expect(throws: SearchDictionaryError.checksumMismatch) {
                try await service.selectNeologd(SearchNeologdCatalog.fallback[0], session: session)
            }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.selectNeologd(SearchNeologdCatalog.fallback[1], session: session)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let after = try await service.snapshot()
            #expect(after.preferred == initial.preferred)
            #expect(after.active == initial.active)
            #expect(after.installedNeologdIDs.isEmpty)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'")
            } == before)
        }

        private static func release(
            _ version: String,
            prerelease: Bool = false,
            draft: Bool = false,
            digest: String? = "sha256:" + String(repeating: "a", count: 64),
            assetName: String? = nil
        ) -> [String: Any] {
            [
                "tag_name": "v" + version, "prerelease": prerelease, "draft": draft,
                "assets": [["name": assetName ?? "lindera-ipadic-neologd-\(version).zip", "digest": digest as Any? ?? NSNull(), "size": 123]],
            ]
        }

        private static func session(firstPage: [[String: Any]], secondPage: [[String: Any]] = [], status: Int = 200) throws -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NeologdTestURLProtocol.self]
            configuration.httpAdditionalHeaders = try [
                "X-Test-First": JSONSerialization.data(withJSONObject: firstPage).base64EncodedString(),
                "X-Test-Second": JSONSerialization.data(withJSONObject: secondPage).base64EncodedString(),
                "X-Test-Status": String(status),
            ]
            return URLSession(configuration: configuration)
        }
    }

    /// Each session carries immutable response fixtures in headers; there is no shared mutable handler state.
    private final class NeologdTestURLProtocol: URLProtocol, @unchecked Sendable {
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let second = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "page", value: "2")) == true
            let bytes = Data(base64Encoded: request.value(forHTTPHeaderField: second ? "X-Test-Second" : "X-Test-First")!)!
            let status = Int(request.value(forHTTPHeaderField: "X-Test-Status")!)!
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
