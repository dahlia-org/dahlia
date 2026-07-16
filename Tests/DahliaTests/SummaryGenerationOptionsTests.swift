@testable import Dahlia

#if canImport(Testing)
import Testing

struct SummaryGenerationOptionsTests {
    @Test
    func mergingUsesLargestPreviousMeetingCountAndCombinesExports() {
        let merged = SummaryGenerationOptions.merging([
            SummaryGenerationOptions(
                previousMeetingCount: 1,
                exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false)
            ),
            SummaryGenerationOptions(
                previousMeetingCount: 5,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true)
            ),
        ])

        #expect(merged.previousMeetingCount == 5)
        #expect(merged.exportOptions == SummaryExportOptions(
            exportsToVault: true,
            exportsToGoogleDocs: true
        ))
    }
}
#endif
