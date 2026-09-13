@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryExportOptionsTests {
        @Test
        func mergesWorkspaceAndGoogleDocsIndependently() {
            let merged = SummaryExportOptions.merging([
                SummaryExportOptions(exportsToWorkspace: true, exportsToGoogleDocs: false),
                SummaryExportOptions(exportsToWorkspace: false, exportsToGoogleDocs: true),
            ])

            #expect(merged.exportsToWorkspace)
            #expect(merged.exportsToGoogleDocs)
        }

        @Test
        func manualSummaryKeepsExistingWorkspaceExportBehavior() {
            #expect(SummaryExportOptions.manual.exportsToWorkspace)
            #expect(!SummaryExportOptions.manual.exportsToGoogleDocs)
        }
    }
#endif
