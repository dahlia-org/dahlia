import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ServerCapabilitiesTests {
        @Test
        func decodesSupportedFeaturesAndIgnoresUnknownFields() throws {
            let data = Data(#"""
            {
              "sync": { "version": 3 },
              "recordingArchive": { "version": 1 },
              "meetingEvents": { "version": 1 },
              "search": { "version": 1 },
              "imageAnalysis": { "version": 1 },
              "meetingSummaryGeneration": { "version": 1, "sources": ["transcript", "audio"] },
              "futureFeature": { "enabled": true }
            }
            """#.utf8)
            let capabilities = try JSONDecoder().decode(ServerCapabilities.self, from: data)
            #expect(capabilities.sync?.version == 3)
            #expect(capabilities.recordingArchive?.version == 1)
            #expect(capabilities.meetingEvents?.version == 1)
            #expect(capabilities.search?.version == 1)
            #expect(capabilities.imageAnalysis?.version == 1)
            #expect(capabilities.meetingSummaryGeneration?.version == 1)
            #expect(capabilities.meetingSummaryGeneration?.sources == ["transcript", "audio"])
        }

        @Test
        func omittedFeaturesAreUnsupported() throws {
            let capabilities = try JSONDecoder().decode(ServerCapabilities.self, from: Data("{}".utf8))
            #expect(capabilities.sync == nil)
            #expect(capabilities.recordingArchive == nil)
            #expect(capabilities.meetingEvents == nil)
            #expect(capabilities.search == nil)
            #expect(capabilities.imageAnalysis == nil)
            #expect(capabilities.meetingSummaryGeneration == nil)
        }
    }
#endif
