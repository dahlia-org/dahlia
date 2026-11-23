#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import ImageIO
    import Synchronization
    import Testing
    import UniformTypeIdentifiers
    @testable import Dahlia

    @MainActor
    struct ScreenshotFilePersistenceTests {

        @Test
        func localThumbnailsAreStoredOnFirstReadAndReusedAfterward() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            let thumbnailURL = fixture.directory.appending(path: fixture.source.cacheKey(variant: .thumbnail))
            #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path))

            let first = try await fixture.provider.content(id: fixture.image.id, variant: .thumbnail, dbQueue: queue)
            #expect(first.variant == .thumbnail)
            #expect(await pollUntil { FileManager.default.fileExists(atPath: thumbnailURL.path) })

            // Later reads use the stored copy and never open the original.
            try FileManager.default.removeItem(at: fixture.imageURL)
            let second = try await fixture.provider.content(id: fixture.image.id, variant: .thumbnail, dbQueue: queue)
            #expect(second.data == first.data)
        }

        @Test
        func captureFailureNeverPublishesARecordWithoutItsFile() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try FileManager.default.createDirectory(at: fixture.imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([99]).write(to: fixture.imageURL)
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            }
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchCount($0) } == 0)
            #expect(try Data(contentsOf: fixture.imageURL) == Data([99]))
            try FileManager.default.removeItem(at: fixture.imageURL)
            try await queue.write { db in
                try db
                    .execute(
                        sql: "CREATE TRIGGER reject_capture BEFORE INSERT ON meeting_attachments BEGIN SELECT RAISE(ABORT, 'injected commit failure'); END"
                    )
            }
            await #expect(throws: (any Error).self) { try await fixture.provider.persistCapture(fixture.image, dbQueue: queue) }
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchCount($0) } == 0)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_operations") } == 0)
            try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_capture") }
            try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        @Test
        func helperCachedImageReportsAccessToTheApp() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            try await fixture.provider.persistCapture(fixture.image, dbQueue: fixture.database.dbQueue)
            let calls = Mutex(0)
            let helperWorkspaceId = fixture.workspace.id
            let meetingId = fixture.image.meetingId
            let helper = try MeetingAccessStore(
                databaseURL: fixture.databaseURL, workspaceID: fixture.workspace.id,
                screenshotCache: ScreenshotFileStore(directory: fixture.directory, readOnly: true),
                imageResolver: { _, _, _ in throw ScreenshotContentError.unavailable },
                textResolver: { workspaceId, request in
                    #expect(workspaceId == helperWorkspaceId)
                    #expect(request.operation == .touch)
                    #expect(request.entity == .file)
                    #expect(request.meetingId == meetingId)
                    calls.withLock { $0 += 1 }
                    return Data("{}".utf8)
                }
            )
            #expect(try helper.screenshot(meetingID: fixture.image.meetingId, screenshotID: fixture.image.id).imageData == fixture
                .bytes)
            #expect(calls.withLock { $0 } == 1)
        }

        @Test
        func failedLegacyFileMigrationPreservesBlobAndCanRetry() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try await queue.write { try fixture.image.insertLegacyForTesting($0) }
            try FileManager.default.createDirectory(at: fixture.imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([99]).write(to: fixture.imageURL)
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await fixture.provider.migrateLegacyImages(workspaceId: fixture.workspace.id, dbQueue: queue)
            }
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == fixture.bytes)
            try FileManager.default.removeItem(at: fixture.imageURL)
            try await fixture.provider.migrateLegacyImages(workspaceId: fixture.workspace.id, dbQueue: queue)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        @Test
        func localConversionReencodesLegacyScreenshotsOnceAndKeepsTheirText() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            let legacy = try Self.legacyJPEG(replacing: fixture.image)
            try await fixture.provider.persistCapture(legacy, dbQueue: queue)
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE file_text_bodies SET ocrText = 'OCR', caption = 'Caption' WHERE fileId = ?",
                    arguments: [legacy.id]
                )
            }
            let smallWebP = try Self.encodedImage(width: 800, height: 500, type: .webP)
            let small = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: legacy.meetingId,
                capturedAt: .now,
                imageData: smallWebP,
                mimeType: "image/webp"
            )
            try await fixture.provider.persistCapture(small, dbQueue: queue)

            try await fixture.provider.convertLocalScreenshots(dbQueue: queue)

            let converted = try #require(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: legacy.id) })
            let convertedFileId = try #require(converted.fileId)
            #expect(convertedFileId != legacy.id)
            #expect(converted.mimeType == "image/webp")
            #expect(converted.ocrText == "OCR")
            #expect(converted.caption == "Caption")
            let bytes = try await fixture.provider.content(id: legacy.id, dbQueue: queue).data
            #expect(ImageEncoder.mimeType(for: bytes) == "image/webp")
            let size = try #require(ImageEncoder.pixelSize(of: bytes))
            #expect(max(size.width, size.height) == ImageEncoder.screenshotMaximumLongEdge)
            #expect(try await queue.read { try FileRecord.fetchOne($0, key: legacy.id) } == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.imageURL.path))
            #expect(try await fixture.provider.content(id: small.id, dbQueue: queue).data == smallWebP)

            try await fixture.provider.convertLocalScreenshots(dbQueue: queue)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: legacy.id)?.fileId } == convertedFileId)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: small.id)?.fileId } == small.id)
        }

        /// A screenshot as saved before the WebP format and long-edge limit: a full Retina-size JPEG.
        private static func legacyJPEG(replacing image: MeetingScreenshotRecord) throws -> MeetingScreenshotRecord {
            var legacy = image
            legacy.imageData = try encodedImage(width: 3456, height: 2234, type: .jpeg)
            legacy.mimeType = "image/jpeg"
            return legacy
        }

        private static func encodedImage(width: Int, height: Int, type: UTType) throws -> Data {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            if type == .webP { return try #require(ImageEncoder.encode(image)) }
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }

        private struct Fixture {
            let root: URL
            let directory: URL
            let databaseURL: URL
            let database: AppDatabaseManager
            let files: ScreenshotFileStore
            let provider: ScreenshotContentProvider
            let workspace: WorkspaceRecord
            let image: MeetingScreenshotRecord
            let bytes: Data
            let source: ScreenshotRemoteReference
            var imageURL: URL { directory.appending(path: "\(source.cacheKey(variant: .original))") }

            @MainActor
            init() throws {
                root = FileManager.default.temporaryDirectory.appending(path: "image-persistence-\(UUID().uuidString)")
                directory = root.appending(path: "FileStore")
                databaseURL = root.appending(path: "test.sqlite")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                database = try AppDatabaseManager(path: databaseURL.path)
                files = try ScreenshotFileStore(directory: directory)
                provider = ScreenshotContentProvider(cache: files)
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Files", createdAt: .now, lastOpenedAt: .now)
                self.workspace = workspace
                let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
                bytes = try #require(TestScreenshotImageFixture.data(using: .png))
                image = MeetingScreenshotRecord(id: .v7(), meetingId: meeting.id, capturedAt: .now, imageData: bytes, mimeType: "image/png")
                source = ScreenshotRemoteReference(
                    origin: "",
                    accountConnectionId: nil,
                    fileId: image.id,
                    contentHash: ScreenshotRemoteReference.digest(bytes)
                )
                try database.dbQueue.write { db in
                    try workspace.insert(db)
                    try meeting.insert(db)
                }
            }

            func removeFiles() {
                try? database.close()
                try? FileManager.default.removeItem(at: root)
            }
        }
    }
#endif
