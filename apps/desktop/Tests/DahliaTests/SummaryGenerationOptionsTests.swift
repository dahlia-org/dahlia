@testable import Dahlia

#if canImport(Testing)
    import Foundation
    import Testing

    @MainActor
    struct SummaryGenerationOptionsTests {
        @Test
        func batchDefaultsUseAccountStyleInEitherLocationWithoutChangingExports() {
            let local = AppSettings.shared.batchSummaryGenerationOptions()
            var server = ServerAccountSettings.initialValues()
            server.processing = .init(location: .remote)
            server.summary = .init(style: .standard)
            let options = AppSettings.shared.batchSummaryGenerationOptions(serverSettings: server)
            #expect(options.detailLevel == .standard)
            #expect(options.exportOptions == local.exportOptions)
            #expect(local.detailLevel == AppSettings.shared.summaryDetailLevel)
            let unavailable = AppSettings.shared.batchSummaryGenerationOptions(serverSettings: nil)
            #expect(unavailable.detailLevel == nil)
            #expect(unavailable.exportOptions == local.exportOptions)
            let loaded = SummaryGenerationSettings.current(accountSettings: server)
                .applying(accountSettings: server, connectionID: .v7(), detailLevel: unavailable.detailLevel)
            #expect(loaded.detailLevelInstruction == SummaryDetailLevel.standard.instruction)
            server.processing?.location = .local
            #expect(AppSettings.shared.batchSummaryGenerationOptions(serverSettings: server).detailLevel == .standard)
        }

        @Test
        func mergingCombinesExports() {
            let merged = SummaryGenerationOptions.merging([
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: true, exportsToGoogleDocs: false),
                    detailLevel: .standard
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: false, exportsToGoogleDocs: true),
                    detailLevel: .eventSession
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: false, exportsToGoogleDocs: false),
                    detailLevel: .detailed
                ),
            ])

            #expect(merged.exportOptions == SummaryExportOptions(
                exportsToWorkspace: true,
                exportsToGoogleDocs: true
            ))
            #expect(merged.detailLevel == .eventSession)
        }

        @Test
        func sourceIsBackwardCompatibleAndMergedWithManualOptions() throws {
            let legacy = try JSONDecoder().decode(
                SummaryGenerationOptions.self,
                from: Data(#"{"exportOptions":{"exportsToWorkspace":true,"exportsToGoogleDocs":false},"detailLevel":"high"}"#.utf8)
            )
            #expect(legacy.source == nil)

            let merged = SummaryGenerationOptions.merging([
                legacy,
                SummaryGenerationOptions(exportOptions: .manual, source: .audio),
            ])
            #expect(merged.source == SummaryGenerationSource.audio)
        }
    }
#endif
