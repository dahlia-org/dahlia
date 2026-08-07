import CryptoKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct SpeakerModelAssetCancellationTests {
        @Test
        func cancellingOneConcurrentRequestDoesNotCancelSharedDownload() async throws {
            let fixture = makeCancellationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let fetcher = GatedFetcher(data: fixture.data)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )
            let firstProgress = ProgressProbe()
            let secondProgress = ProgressProbe()
            let cancelledRequest = Task {
                try await manager.acquire { _ in
                    Task { await firstProgress.recordUpdate() }
                }
            }
            await firstProgress.waitForUpdate()
            await fetcher.waitUntilBlocked()
            let survivingRequest = Task {
                try await manager.acquire { _ in
                    Task { await secondProgress.recordUpdate() }
                }
            }
            await secondProgress.waitForUpdate()

            cancelledRequest.cancel()
            do {
                _ = try await cancelledRequest.value
                Issue.record("Expected the cancelled request to stop waiting")
            } catch is CancellationError {
                // Expected. The shared download remains owned by the surviving request.
            }

            await fetcher.release()

            #expect(try await survivingRequest.value == fixture.repositoryURL)
            #expect(await fetcher.requestCount == 1)
            #expect(FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
            #expect(temporaryEntries(in: fixture.revisionRootURL).isEmpty)
        }
    }

    private struct SpeakerModelCancellationFixture {
        let rootURL: URL
        let revisionRootURL: URL
        let repositoryURL: URL
        let manifest: SpeakerModelAssetManifest
        let data: Data
    }

    private func makeCancellationFixture() -> SpeakerModelCancellationFixture {
        let data = Data("model".utf8)
        let file = SpeakerModelAssetManifest.File(
            relativePath: "Embedding.mlmodelc/coremldata.bin",
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        let manifest = SpeakerModelAssetManifest(
            repository: "owner/model",
            revision: "revision",
            license: "fixture",
            totalByteCount: file.byteCount,
            files: [file]
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-speaker-cancellation-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
        let revisionRootURL = rootURL.appending(path: manifest.revision, directoryHint: .isDirectory)
        let repositoryURL = revisionRootURL.appending(
            path: SpeakerModelAssetManager.repositoryFolderName,
            directoryHint: .isDirectory
        )
        return SpeakerModelCancellationFixture(
            rootURL: rootURL,
            revisionRootURL: revisionRootURL,
            repositoryURL: repositoryURL,
            manifest: manifest,
            data: data
        )
    }

    private func temporaryEntries(in revisionRootURL: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: revisionRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".temporary") }) ?? []
    }

    private actor GatedFetcher: SpeakerModelAssetFetching {
        let data: Data
        private(set) var requestCount = 0
        private var isBlocked = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        init(data: Data) {
            self.data = data
        }

        func data(from _: URL) async -> Data {
            requestCount += 1
            isBlocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
            return data
        }

        func waitUntilBlocked() async {
            guard !isBlocked else { return }
            await withCheckedContinuation { blockedWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor ProgressProbe {
        private var receivedUpdate = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func recordUpdate() {
            receivedUpdate = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }

        func waitForUpdate() async {
            guard !receivedUpdate else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
#endif
