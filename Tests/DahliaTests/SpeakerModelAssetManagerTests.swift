import CryptoKit
import FluidAudio
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct SpeakerModelAssetManagerTests {
        @Test
        func bundledManifestCoversEveryPinnedBundleFileWithRealDigests() throws {
            let bundledManifestURL = Bundle.appModule.url(
                forResource: "SpeakerDiarizationModelManifest", withExtension: "json"
            )
            #expect(bundledManifestURL != nil)
            let manifest = try SpeakerModelAssetManifest.bundled()
            let expectedPaths = Set([
                "Segmentation.mlmodelc/analytics/coremldata.bin",
                "Segmentation.mlmodelc/coremldata.bin",
                "Segmentation.mlmodelc/metadata.json",
                "Segmentation.mlmodelc/model.mil",
                "Segmentation.mlmodelc/weights/weight.bin",
                "FBank.mlmodelc/analytics/coremldata.bin",
                "FBank.mlmodelc/coremldata.bin",
                "FBank.mlmodelc/metadata.json",
                "FBank.mlmodelc/model.mil",
                "FBank.mlmodelc/weights/weight.bin",
                "Embedding.mlmodelc/analytics/coremldata.bin",
                "Embedding.mlmodelc/coremldata.bin",
                "Embedding.mlmodelc/metadata.json",
                "Embedding.mlmodelc/model.mil",
                "Embedding.mlmodelc/weights/weight.bin",
                "PldaRho.mlmodelc/analytics/coremldata.bin",
                "PldaRho.mlmodelc/coremldata.bin",
                "PldaRho.mlmodelc/metadata.json",
                "PldaRho.mlmodelc/model.mil",
                "PldaRho.mlmodelc/weights/weight.bin",
                "plda-parameters.json",
            ])

            #expect(manifest.repository == "FluidInference/speaker-diarization-coreml")
            #expect(manifest.revision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
            #expect(manifest.license == "CC BY 4.0")
            #expect(Set(manifest.files.map(\.relativePath)) == expectedPaths)
            #expect(manifest.files.allSatisfy { $0.byteCount > 0 })
            #expect(manifest.files.allSatisfy { $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
            #expect(manifest.files.reduce(Int64(0)) { $0 + $1.byteCount } == 21_599_417)
            #expect(manifest.totalByteCount == 21_599_417)
        }

        @Test
        func installedFolderMatchesFluidAudioRepositoryFolder() {
            #expect(SpeakerModelAssetManager.repositoryFolderName == Repo.diarizer.folderName)
            #expect(SpeakerModelAssetManager.repositoryFolderName == "speaker-diarization")
        }

        @Test
        func downloadURLPinsRepositoryRevisionAndRelativePath() {
            let manifest = fixtureManifest()

            let url = SpeakerModelAssetManager.downloadURL(for: manifest.files[0], manifest: manifest)

            let expectedURL = "https://huggingface.co/owner/model/resolve/revision/Embedding.mlmodelc/coremldata.bin"
            #expect(url.absoluteString == expectedURL)
        }

        @Test
        func partialDownloadIsRejectedAndTemporaryAssetsAreRemoved() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let firstFile = fixture.manifest.files[0]
            let firstURL = SpeakerModelAssetManager.downloadURL(for: firstFile, manifest: fixture.manifest)
            let fetcher = StaticSpeakerAssetFetcher(dataByURL: [firstURL: Data("x".utf8)])
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )

            do {
                try await manager.acquire()
                Issue.record("Expected a partial download to fail")
            } catch let error as SpeakerModelAssetError {
                let expected = SpeakerModelAssetError.byteCountMismatch(
                    path: firstFile.relativePath, expected: firstFile.byteCount, actual: 1
                )
                #expect(error == expected)
            }

            #expect(!FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
            #expect(temporaryEntries(in: fixture.revisionRootURL).isEmpty)
        }

        @Test
        func cancellationRemovesTemporaryAssets() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let fetcher = CancellingSpeakerAssetFetcher()
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )
            let acquisition = Task {
                try await manager.acquire()
            }
            await fetcher.waitUntilStarted()
            acquisition.cancel()
            do {
                _ = try await acquisition.value
                Issue.record("Expected acquisition cancellation")
            } catch is CancellationError {
                // Expected.
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
            #expect(temporaryEntries(in: fixture.revisionRootURL).isEmpty)
        }

        @Test
        func checksumMismatchIsRejected() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            var dataByURL = fixture.dataByURL
            let firstFile = fixture.manifest.files[0]
            dataByURL[SpeakerModelAssetManager.downloadURL(for: firstFile, manifest: fixture.manifest)] =
                Data(repeating: 0, count: Int(firstFile.byteCount))
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: StaticSpeakerAssetFetcher(dataByURL: dataByURL)
            )

            do {
                try await manager.acquire()
                Issue.record("Expected a checksum mismatch")
            } catch let error as SpeakerModelAssetError {
                #expect(error == .checksumMismatch(path: firstFile.relativePath))
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
        }

        @Test
        func installAppearsOnlyAfterEveryFileIsVerified() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let fetcher = GatedSpeakerAssetFetcher(dataByURL: fixture.dataByURL, blockedRequestNumber: 2)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )
            let acquisition = Task {
                try await manager.acquire()
            }
            await fetcher.waitUntilBlocked()

            #expect(!FileManager.default.fileExists(atPath: fixture.repositoryURL.path))

            await fetcher.release()
            let installedURL = try await acquisition.value
            #expect(installedURL == fixture.repositoryURL)
            #expect(FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
            #expect(try await manager.onDiskUsage() == fixture.manifest.totalByteCount)
        }

        @Test
        func corruptInstallCanBeReacquired() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            try writeInstalledFixture(fixture)
            try Data("other".utf8).write(to: fixture.repositoryURL.appending(path: fixture.manifest.files[0].relativePath))
            let fetcher = StaticSpeakerAssetFetcher(dataByURL: fixture.dataByURL)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )

            _ = try await manager.acquire()

            #expect(await fetcher.requestCount() == fixture.manifest.files.count)
            #expect(try await manager.verifiedRevisionRootURL() == fixture.revisionRootURL)
        }

        @Test
        func healthyInstallIsPreservedWithoutDownloading() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            try writeInstalledFixture(fixture)
            let markerURL = fixture.repositoryURL.appending(path: ".DS_Store")
            try Data("finder metadata".utf8).write(to: markerURL)
            let fetcher = StaticSpeakerAssetFetcher(dataByURL: [:])
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )

            let installedURL = try await manager.acquire()

            #expect(installedURL == fixture.repositoryURL)
            #expect(await fetcher.requestCount() == 0)
            #expect(FileManager.default.fileExists(atPath: markerURL.path))
        }

        @Test
        func concurrentAcquireUsesOneDownloadAndOneAtomicInstall() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let fetcher = GatedSpeakerAssetFetcher(dataByURL: fixture.dataByURL, blockedRequestNumber: 1)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: fetcher
            )
            let first = Task { try await manager.acquire() }
            await fetcher.waitUntilBlocked()
            let second = Task { try await manager.acquire() }

            await fetcher.release()

            #expect(try await first.value == fixture.repositoryURL)
            #expect(try await second.value == fixture.repositoryURL)
            #expect(await fetcher.receivedRequestCount() == fixture.manifest.files.count)
            #expect(temporaryEntries(in: fixture.revisionRootURL).isEmpty)
        }

        @Test
        func acquisitionStreamReportsProgressThroughCompletion() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: StaticSpeakerAssetFetcher(dataByURL: fixture.dataByURL)
            )
            var updates: [SpeakerModelAssetProgress] = []

            for try await update in await manager.acquisition() {
                updates.append(update)
            }

            #expect(updates.first?.completedByteCount == 0)
            #expect(updates.last?.completedByteCount == fixture.manifest.totalByteCount)
            #expect(updates.last?.currentFile == fixture.manifest.files.last?.relativePath)
        }

        @Test
        func onDiskUsageExcludesCoreMLCachesOutsideManagedRoot() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            try writeInstalledFixture(fixture)
            let externalCacheURL = fixture.rootURL.deletingLastPathComponent()
                .appending(path: "com.apple.CoreML-\(UUID.v7().uuidString).cache")
            defer { try? FileManager.default.removeItem(at: externalCacheURL) }
            try Data(repeating: 0, count: 1024).write(to: externalCacheURL)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: StaticSpeakerAssetFetcher(dataByURL: [:])
            )

            #expect(try await manager.onDiskUsage() == fixture.manifest.totalByteCount)
        }

        @Test
        func processBootstrapAlwaysRestoresOfflineMode() {
            ModelHub.offlineMode = false
            AppDelegate.bootstrapProcessDependencies()
            #expect(ModelHub.offlineMode)
            ModelHub.offlineMode = false
            AppDelegate.bootstrapProcessDependencies()
            #expect(ModelHub.offlineMode)
        }

        @Test
        func realFluidAudioLoaderFindsLibraryNamedCustomCache() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            try writeInstalledFixture(fixture)
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: StaticSpeakerAssetFetcher(dataByURL: [:])
            )
            let runtime = SpeakerDiarizationRuntime(assetManager: manager)
            ModelHub.offlineMode = false
            do {
                try await runtime.loadVerifiedModels()
                Issue.record("Expected fixture Core ML contents to be rejected")
            } catch let DownloadError.modelMissing(repo, missing) {
                Issue.record("FluidAudio did not resolve the installed directory: \(repo), missing: \(missing)")
            } catch {
                // Reaching Core ML layout validation proves FluidAudio found every required bundle.
            }
            #expect(ModelHub.offlineMode)
            #expect(fixture.repositoryURL.lastPathComponent == Repo.diarizer.folderName)
            #expect(FileManager.default.fileExists(atPath: fixture.repositoryURL.path))
        }

        @Test
        func missingOrCorruptAssetsFailDahliaVerificationWhileOffline() async throws {
            let fixture = makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let manager = try SpeakerModelAssetManager(
                managedRootURL: fixture.rootURL,
                manifest: fixture.manifest,
                fetcher: StaticSpeakerAssetFetcher(dataByURL: [:])
            )
            let runtime = SpeakerDiarizationRuntime(assetManager: manager)
            SpeakerDiarizationBootstrap.startProcess()

            do {
                try await runtime.loadVerifiedModels()
                Issue.record("Expected missing assets to prevent loading")
            } catch let error as SpeakerModelAssetError {
                #expect(error == .missingFile(fixture.manifest.files[0].relativePath))
            }
            #expect(ModelHub.offlineMode)

            try writeInstalledFixture(fixture)
            let corruptFileURL = fixture.repositoryURL.appending(path: fixture.manifest.files[0].relativePath)
            try Data(repeating: 0, count: Int(fixture.manifest.files[0].byteCount)).write(to: corruptFileURL)

            do {
                try await runtime.loadVerifiedModels()
                Issue.record("Expected corrupt assets to prevent loading")
            } catch let error as SpeakerModelAssetError {
                #expect(error == .checksumMismatch(path: fixture.manifest.files[0].relativePath))
            }

            #expect(ModelHub.offlineMode)
        }
    }

    private struct SpeakerAssetFixture {
        let rootURL: URL
        let revisionRootURL: URL
        let repositoryURL: URL
        let manifest: SpeakerModelAssetManifest
        let dataByURL: [URL: Data]
    }

    private func fixtureManifest() -> SpeakerModelAssetManifest {
        let modelDataByPath = [
            "Segmentation.mlmodelc/coremldata.bin": Data("segmentation".utf8),
            "FBank.mlmodelc/coremldata.bin": Data("fbank".utf8),
            "Embedding.mlmodelc/coremldata.bin": Data("embedding".utf8),
            "PldaRho.mlmodelc/coremldata.bin": Data("plda rho".utf8),
        ]
        let parametersData = Data("parameters".utf8)
        let files = modelDataByPath.sorted { $0.key < $1.key }.map { path, data in
            SpeakerModelAssetManifest.File(
                relativePath: path,
                byteCount: Int64(data.count),
                sha256: digest(data)
            )
        } + [
            .init(
                relativePath: "plda-parameters.json",
                byteCount: Int64(parametersData.count),
                sha256: digest(parametersData)
            ),
        ]
        return SpeakerModelAssetManifest(
            repository: "owner/model",
            revision: "revision",
            license: "fixture",
            totalByteCount: files.reduce(0) { $0 + $1.byteCount },
            files: files
        )
    }

    private func makeFixture() -> SpeakerAssetFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-speaker-assets-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
        let manifest = fixtureManifest()
        let revisionRootURL = rootURL.appending(path: manifest.revision, directoryHint: .isDirectory)
        let repositoryURL = revisionRootURL.appending(
            path: SpeakerModelAssetManager.repositoryFolderName,
            directoryHint: .isDirectory
        )
        let sourceData = ["embedding", "fbank", "plda rho", "segmentation", "parameters"].map { Data($0.utf8) }
        let dataByURL = Dictionary(uniqueKeysWithValues: zip(manifest.files, sourceData).map { file, data in
            (SpeakerModelAssetManager.downloadURL(for: file, manifest: manifest), data)
        })
        return .init(
            rootURL: rootURL,
            revisionRootURL: revisionRootURL,
            repositoryURL: repositoryURL,
            manifest: manifest,
            dataByURL: dataByURL
        )
    }

    private func writeInstalledFixture(_ fixture: SpeakerAssetFixture) throws {
        for file in fixture.manifest.files {
            let destinationURL = fixture.repositoryURL.appending(path: file.relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sourceURL = SpeakerModelAssetManager.downloadURL(for: file, manifest: fixture.manifest)
            try fixture.dataByURL[sourceURL]?.write(to: destinationURL)
        }
    }

    private func temporaryEntries(in revisionRootURL: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: revisionRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".temporary") }) ?? []
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private actor StaticSpeakerAssetFetcher: SpeakerModelAssetFetching {
        private let dataByURL: [URL: Data]
        private var requests: [URL] = []

        init(dataByURL: [URL: Data]) {
            self.dataByURL = dataByURL
        }

        func data(from url: URL) throws -> Data {
            requests.append(url)
            guard let data = dataByURL[url] else {
                throw SpeakerModelAssetError.invalidResponse(url)
            }
            return data
        }

        func requestCount() -> Int {
            requests.count
        }
    }

    private actor CancellingSpeakerAssetFetcher: SpeakerModelAssetFetching {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func data(from _: URL) async throws -> Data {
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            try await Task.sleep(for: .seconds(120))
            return Data()
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor GatedSpeakerAssetFetcher: SpeakerModelAssetFetching {
        private let dataByURL: [URL: Data]
        private let blockedRequestNumber: Int
        private var requestCount = 0
        private var blocked = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        init(dataByURL: [URL: Data], blockedRequestNumber: Int) {
            self.dataByURL = dataByURL
            self.blockedRequestNumber = blockedRequestNumber
        }

        func data(from url: URL) async throws -> Data {
            requestCount += 1
            if requestCount == blockedRequestNumber {
                blocked = true
                blockedWaiters.forEach { $0.resume() }
                blockedWaiters.removeAll()
                await withCheckedContinuation { releaseContinuation = $0 }
            }
            guard let data = dataByURL[url] else {
                throw SpeakerModelAssetError.invalidResponse(url)
            }
            return data
        }

        func waitUntilBlocked() async {
            guard !blocked else { return }
            await withCheckedContinuation { blockedWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func receivedRequestCount() -> Int {
            requestCount
        }
    }
#endif
