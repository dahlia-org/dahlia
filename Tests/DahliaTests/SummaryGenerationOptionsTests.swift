@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryGenerationOptionsTests {
        @Test
        func mergingCombinesExports() {
            let merged = SummaryGenerationOptions.merging([
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false)
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true)
                ),
            ])

            #expect(merged.exportOptions == SummaryExportOptions(
                exportsToVault: true,
                exportsToGoogleDocs: true
            ))
        }
    }
#endif
