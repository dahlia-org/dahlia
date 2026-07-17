@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryExportOptionsTests {
        @Test
        func mergesVaultAndGoogleDocsIndependently() {
            let merged = SummaryExportOptions.merging([
                SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false),
                SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true),
            ])

            #expect(merged.exportsToVault)
            #expect(merged.exportsToGoogleDocs)
        }

        @Test
        func manualSummaryKeepsExistingVaultExportBehavior() {
            #expect(SummaryExportOptions.manual.exportsToVault)
            #expect(!SummaryExportOptions.manual.exportsToGoogleDocs)
        }
    }
#endif
