#if canImport(Testing)
    import DahliaRuntimeSupport
    import Darwin
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaImageBrokerTests {
        @Test
        func transfersBinaryImagesAndRejectsUntrustedExecutables() async throws {
            let root = URL(filePath: "/tmp/dahlia-image-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appending(path: "image.sock")
            let request = DahliaImageBrokerProtocol.Request(vaultId: .v7(), meetingId: .v7(), screenshotId: .v7())
            let bytes = Data(repeating: 0xAB, count: 128 * 1024)
            let broker = DahliaImageBrokerServer(helperURL: executableURL()) { _ in bytes }
            try broker.start(socketURL: socket)
            let received = try await Task.detached {
                try DahliaImageBrokerProtocol.requestImage(request, socketURL: socket)
            }.value
            #expect(received == bytes)
            broker.stop()
            #expect(!FileManager.default.fileExists(atPath: socket.path))
            let called = Mutex(false)
            let denied = DahliaImageBrokerServer(helperURL: root.appending(path: "different-helper")) { _ in
                called.withLock { $0 = true }
                return bytes
            }
            try denied.start(socketURL: socket)
            defer { denied.stop() }
            await #expect(throws: (any Error).self) {
                try await Task.detached {
                    try DahliaImageBrokerProtocol.requestImage(request, socketURL: socket)
                }.value
            }
            #expect(!called.withLock { $0 })
        }

        @Test
        func databaseResolverRejectsCrossVaultRequests() async throws {
            let root = URL(filePath: "/tmp/dahlia-image-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appending(path: "image.sock")
            let db = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(id: .v7(), path: nil, name: "Fixture", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, projectId: nil, name: "Fixture", createdAt: .now, updatedAt: .now)
            let imageId = UUID.v7()
            try await db.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try db.execute(
                    sql: "INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType) VALUES (?, ?, ?, ?, 'image/png')",
                    arguments: [imageId, meeting.id, Date(), Data([1, 2, 3])]
                )
            }
            let broker = DahliaImageBrokerServer(dbQueue: db.dbQueue, helperURL: executableURL())
            try broker.start(socketURL: socket)
            defer { broker.stop() }
            let valid = DahliaImageBrokerProtocol.Request(vaultId: vault.id, meetingId: meeting.id, screenshotId: imageId)
            #expect(try await Task.detached { try DahliaImageBrokerProtocol.requestImage(valid, socketURL: socket) }.value == Data([1, 2, 3]))
            let invalid = DahliaImageBrokerProtocol.Request(vaultId: .v7(), meetingId: meeting.id, screenshotId: imageId)
            await #expect(throws: (any Error).self) {
                try await Task.detached { try DahliaImageBrokerProtocol.requestImage(invalid, socketURL: socket) }.value
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func stoppingBrokerCancelsItsInFlightRetrieval() async throws {
            let root = URL(filePath: "/tmp/dahlia-image-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appending(path: "image.sock")
            let (events, continuation) = AsyncStream.makeStream(of: String.self)
            let broker = DahliaImageBrokerServer(helperURL: executableURL()) { _ in
                continuation.yield("started")
                do {
                    // Stand in for a suspended network read; only cancellation completes it.
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    continuation.yield("cancelled")
                    throw error
                }
                return Data([1])
            }
            try broker.start(socketURL: socket)
            let request = DahliaImageBrokerProtocol.Request(vaultId: .v7(), meetingId: .v7(), screenshotId: .v7())
            let client = Task.detached { try DahliaImageBrokerProtocol.requestImage(request, socketURL: socket) }
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next() == "started")
            broker.stop()
            #expect(await iterator.next() == "cancelled")
            await #expect(throws: (any Error).self) { try await client.value }
        }

        private func executableURL() -> URL {
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = proc_pidpath(getpid(), &path, UInt32(path.count))
            return URL(filePath: String(decoding: path.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
#endif
