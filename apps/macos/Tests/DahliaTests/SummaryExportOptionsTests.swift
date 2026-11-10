@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryExportOptionsTests {
        @Test
        func mergesWorkspaceExport() {
            let merged = SummaryExportOptions.merging([
                SummaryExportOptions(exportsToWorkspace: true),
                SummaryExportOptions(exportsToWorkspace: false),
            ])

            #expect(merged.exportsToWorkspace)
        }

        @Test
        func manualSummaryKeepsExistingWorkspaceExportBehavior() {
            #expect(SummaryExportOptions.manual.exportsToWorkspace)
        }
    }
#endif
