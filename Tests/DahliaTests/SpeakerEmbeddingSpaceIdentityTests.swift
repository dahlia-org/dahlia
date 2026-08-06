import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerEmbeddingSpaceIdentityTests {
        @Test
        func derivesRuntimeConfigurationIdentity() async throws {
            let rootURL = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-speaker-space-\(UUID.v7().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let manager = try SpeakerModelAssetManager(managedRootURL: rootURL)
            let configuration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()

            let space = await manager.embeddingSpace()

            #expect(space.sampleRate == configuration.segmentation.sampleRate)
            #expect(space.excludesOverlap == configuration.embedding.excludeOverlap)
            #expect(space.preprocessing == SpeakerModelAssetManager.preprocessingDescriptor(configuration: configuration))

            var changedConfiguration = configuration
            changedConfiguration.segmentation.sampleRate = 8000
            #expect(
                SpeakerModelAssetManager.preprocessingDescriptor(configuration: changedConfiguration)
                    != space.preprocessing
            )
        }

        @Test
        func fluidAudioVersionMatchesDependencyPins() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let data = try Data(contentsOf: repositoryRoot.appending(path: "Package.resolved"))
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pins = try #require(json["pins"] as? [[String: Any]])
            let fluidAudio = try #require(pins.first { $0["identity"] as? String == "fluidaudio" })
            let state = try #require(fluidAudio["state"] as? [String: Any])
            let resolvedVersion = try #require(state["version"] as? String)
            let packageSource = try String(
                contentsOf: repositoryRoot.appending(path: "Package.swift"),
                encoding: .utf8
            )
            let versionPattern = #"FluidAudio\.git", exact: "([^"]+)""#
            let expression = try NSRegularExpression(pattern: versionPattern)
            let sourceRange = NSRange(packageSource.startIndex..., in: packageSource)
            let match = try #require(expression.firstMatch(in: packageSource, range: sourceRange))
            let pinnedVersionRange = try #require(Range(match.range(at: 1), in: packageSource))
            let pinnedVersion = String(packageSource[pinnedVersionRange])

            #expect(SpeakerModelAssetManager.fluidAudioVersion == resolvedVersion)
            #expect(SpeakerModelAssetManager.fluidAudioVersion == pinnedVersion)
        }
    }
#endif
