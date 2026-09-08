@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryGenerationOptionsTests {
        @Test(arguments: ["transcript", "audio"])
        func batchDefaultsUseServerDetailWithoutChangingExports(method: String) {
            let local = AppSettings.shared.batchSummaryGenerationOptions()
            var server = ServerAccountSettings.initialValues()
            server.summary = .init(method: method, detail: "standard", methodSettings: .init(
                transcript: .init(), audio: .init(model: "gemini-3-8-flash")
            ))
            let options = AppSettings.shared.batchSummaryGenerationOptions(serverSettings: server)
            #expect(options.detailLevel == .standard)
            #expect(options.exportOptions == local.exportOptions)
            #expect(local.detailLevel == AppSettings.shared.summaryDetailLevel)
            let unavailable = AppSettings.shared.batchSummaryGenerationOptions(serverSettings: nil)
            #expect(unavailable.detailLevel == nil)
            #expect(unavailable.exportOptions == local.exportOptions)
        }

        @Test
        func mergingCombinesExports() {
            let merged = SummaryGenerationOptions.merging([
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false),
                    detailLevel: .standard
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true),
                    detailLevel: .eventSession
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                    detailLevel: .detailed
                ),
            ])

            #expect(merged.exportOptions == SummaryExportOptions(
                exportsToVault: true,
                exportsToGoogleDocs: true
            ))
            #expect(merged.detailLevel == .eventSession)
        }
    }
#endif
