#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ScreenshotContentTests {

        @Test(arguments: [nil, "", " \n\t"] as [String?])
        func absentRemoteAnalysisIsTerminalWithoutDiscardingText(caption: String?) {
            let pending = ScreenshotOCRState.remote(ocrText: "OCR", caption: caption, state: .ready)
            #expect(pending.isTerminal)
            #expect(pending.limitingRemoteWait(to: .seconds(299)) == pending)
            let timedOut = pending.limitingRemoteWait(to: .seconds(300))
            #expect(timedOut == pending)
            #expect(timedOut.isTerminal)
            let complete = ScreenshotOCRState.remote(ocrText: "", caption: "Caption", state: .ready)
            #expect(complete.isTerminal)
            #expect(complete.limitingRemoteWait(to: .seconds(300)) == complete)
            #expect(ScreenshotOCRState.processing.limitingRemoteWait(to: .seconds(300)) == .processing)
        }

        @Test(arguments: [false, true])
        func cachedThumbnailsFollowTheOriginalChecksum(readOnly: Bool) throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root)
            let replacement = ScreenshotRemoteReference(
                origin: fixture.source.origin,
                accountConnectionId: nil,
                fileId: fixture.screenshotId,
                contentHash: ScreenshotRemoteReference.digest(Data([2]))
            )
            try cache.write(ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .original), source: fixture.source)
            try cache.write(ScreenshotContent(data: Data([1]), mimeType: "image/webp", variant: .thumbnail), source: fixture.source)
            let reopened = try ScreenshotFileStore(directory: root, readOnly: readOnly)
            #expect(try reopened.read(replacement, variant: .thumbnail) == nil)
            #expect(try reopened.read(fixture.source, variant: .thumbnail)?.data == Data([1]))
            try cache.write(ScreenshotContent(data: Data([3]), mimeType: "image/webp", variant: .thumbnail), source: replacement)
            #expect(try reopened.read(fixture.source, variant: .thumbnail) == nil)
            #expect(try reopened.read(replacement, variant: .thumbnail)?.data == Data([3]))
            #expect(try reopened.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        @Test
        func cacheIndexUpgradePreservesOriginalsAndRefetchesUnboundThumbnails() throws {
            let fixture = try ScreenshotContentFixture()
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let index = try DatabaseQueue(path: root.appending(path: "index.sqlite").path)
            try index.write { db in
                try db
                    .execute(
                        sql: "CREATE TABLE images (key TEXT PRIMARY KEY, mimeType TEXT NOT NULL, variant TEXT NOT NULL, byteCount INTEGER NOT NULL, digest TEXT NOT NULL, accessedAt REAL NOT NULL)"
                    )
                for variant in [ScreenshotVariant.original, .thumbnail] {
                    let key = fixture.source.cacheKey(variant: variant)
                    let file = root.appending(path: key)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fixture.bytes.write(to: file)
                    try db.execute(
                        sql: "INSERT INTO images VALUES (?, 'image/png', ?, ?, ?, 0)",
                        arguments: [key, variant.rawValue, fixture.bytes.count, fixture.source.contentHash]
                    )
                }
            }
            try index.close()
            let helper = try ScreenshotFileStore(directory: root, readOnly: true)
            #expect(try helper.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try helper.read(fixture.source, variant: .thumbnail) == nil)
            let upgraded = try ScreenshotFileStore(directory: root)
            #expect(try upgraded.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try upgraded.read(fixture.source, variant: .thumbnail) == nil)
            try upgraded.write(ScreenshotContent(data: fixture.bytes, mimeType: "image/png", variant: .thumbnail), source: fixture.source)
            #expect(try upgraded.read(fixture.source, variant: .thumbnail)?.data == fixture.bytes)
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appending(path: "screenshot-content-\(UUID().uuidString)")
        }

    }

    private enum ImageRequestContext {
        @TaskLocal static var kind = ""
    }

    private actor ImageRequestGate {
        nonisolated let events: AsyncStream<String>
        private let continuation: AsyncStream<String>.Continuation
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init() {
            (events, continuation) = AsyncStream.makeStream(of: String.self)
        }

        func enter(_ kind: String) async {
            await withCheckedContinuation { waiter in
                waiting.append(waiter)
                continuation.yield(kind)
            }
        }

        func releaseAll() {
            let current = waiting
            waiting.removeAll()
            current.forEach { $0.resume() }
        }
    }

    private struct ScreenshotContentFixture: Sendable {
        let dbQueue: any DatabaseWriter
        let workspaceId = UUID.v7()
        let meetingId = UUID.v7()
        let screenshotId = UUID.v7()
        let bytes = Data([1, 2, 3, 4, 5, 6])
        let source: ScreenshotRemoteReference

        init(dbQueue: (any DatabaseWriter)? = nil) throws {
            self.dbQueue = try dbQueue ?? AppDatabaseManager(path: ":memory:").dbQueue
            source = ScreenshotRemoteReference(
                origin: "",
                accountConnectionId: nil,
                fileId: screenshotId,
                contentHash: ScreenshotRemoteReference.digest(bytes)
            )
            let workspace = WorkspaceRecord(id: workspaceId, path: nil, name: "Workspace", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: meetingId, workspaceId: workspaceId, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
            try self.dbQueue.write { db in
                try workspace.insert(db)
                try meeting.insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotId,
                    meetingId: meetingId,
                    capturedAt: .now,
                    imageData: bytes,
                    mimeType: "image/png",
                    ocrText: "durable OCR",
                    caption: "durable caption",
                    remoteReference: source.jsonString()
                ).insertLegacyForTesting(db)
            }
        }

        func storedBytes() async throws -> Data? {
            try await dbQueue.read { try MeetingScreenshotRecord.fetchOne($0, key: screenshotId)?.imageData }
        }
    }

    /// URLProtocol callbacks are synchronous here; handler registration is protected across parallel tests.
    final class ImageURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated static func requestJSON(_ request: URLRequest) -> [String: Any]? {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, request.httpBody == nil {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(buffer, count: count)
                }
            }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }

        typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
        private static let handlers = Mutex<[String: Handler]>([:])

        static func register(origin: String, handler: @escaping Handler) { handlers.withLock { $0[URL(string: origin)!.host!] = handler } }
        static func remove(origin: String) { _ = handlers.withLock { $0.removeValue(forKey: URL(string: origin)!.host!) } }
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, let host = url.host, let handler = Self.handlers.withLock({ $0[host] }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            do {
                let (status, headers, bytes) = try handler(PublicIDTestClient.internalRequest(request))
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
                let publicBytes = try PublicIDTestClient.publicResponse(bytes, request: request, status: status)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: publicBytes)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        override func stopLoading() {}
    }
#endif
