import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct WhisperKitBatchLanguageDetectorCacheTests {
        @Test
        func tokenizerCacheRequiresEveryPinnedFile() throws {
            let rootURL = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try writePinnedFiles(
                WhisperKitBatchLanguageDetector.tokenizerRelativePaths,
                revision: WhisperKitBatchLanguageDetector.tokenizerRevision,
                repositoryFolder: rootURL
            )
            #expect(WhisperKitBatchLanguageDetector.hasPinnedTokenizer(repositoryFolder: rootURL))

            try FileManager.default.removeItem(at: rootURL.appending(path: "vocab.json"))

            #expect(!WhisperKitBatchLanguageDetector.hasPinnedTokenizer(repositoryFolder: rootURL))
        }

        @Test
        func modelCacheRequiresPinnedMetadataForEveryModelFile() throws {
            let rootURL = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let modelPaths = WhisperKitBatchLanguageDetector.modelRelativePaths.map {
                "\(WhisperKitBatchLanguageDetector.modelFolderName)/\($0)"
            }
            try writePinnedFiles(
                modelPaths,
                revision: WhisperKitBatchLanguageDetector.modelRevision,
                repositoryFolder: rootURL
            )
            #expect(WhisperKitBatchLanguageDetector.hasPinnedModel(repositoryFolder: rootURL))

            try writeMetadata(
                relativePath: "\(WhisperKitBatchLanguageDetector.modelFolderName)/TextDecoder.mlmodelc/weights/weight.bin",
                revision: "outdated-revision",
                repositoryFolder: rootURL
            )

            #expect(!WhisperKitBatchLanguageDetector.hasPinnedModel(repositoryFolder: rootURL))
        }

        private func makeTemporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appending(path: "dahlia-whisper-cache-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
        }

        private func writePinnedFiles(
            _ relativePaths: [String],
            revision: String,
            repositoryFolder: URL
        ) throws {
            for relativePath in relativePaths {
                let fileURL = repositoryFolder.appending(path: relativePath)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("fixture".utf8).write(to: fileURL)
                try writeMetadata(
                    relativePath: relativePath,
                    revision: revision,
                    repositoryFolder: repositoryFolder
                )
            }
        }

        private func writeMetadata(
            relativePath: String,
            revision: String,
            repositoryFolder: URL
        ) throws {
            let metadataURL = repositoryFolder
                .appending(path: ".cache/huggingface/download", directoryHint: .isDirectory)
                .appending(path: "\(relativePath).metadata")
            try FileManager.default.createDirectory(
                at: metadataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(revision)\netag\n0\n".write(to: metadataURL, atomically: true, encoding: .utf8)
        }
    }
#endif
