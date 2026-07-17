@testable import Dahlia

#if canImport(Testing)
import Testing

struct SummaryGenerationOptionsTests {
    @Test(arguments: [
        (-1, 0),
        (0, 0),
        (3, 3),
        (5, 5),
        (6, 5),
        (Int.max, 5),
    ])
    func previousMeetingCountIsNormalizedForStorageAndPicker(input: Int, expected: Int) {
        #expect(AppSettings.normalizedSummaryPreviousMeetingCount(input) == expected)
    }

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
