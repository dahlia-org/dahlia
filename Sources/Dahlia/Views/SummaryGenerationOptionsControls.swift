import SwiftUI

struct SummaryGenerationOptionsControls: View {
    @Binding var previousMeetingCount: Int
    @Binding var exportsToVault: Bool
    @Binding var exportsToGoogleDocs: Bool
    let isEnabled: Bool

    var body: some View {
        Picker(selection: $previousMeetingCount) {
            ForEach(AppSettings.summaryPreviousMeetingCountOptions, id: \.self) { count in
                Text(count == 0 ? L10n.none : L10n.meetingCount(count))
                    .tag(count)
            }
        } label: {
            VStack(alignment: .leading) {
                Text(L10n.previousMeetingsInSummaryContext)
                Text(L10n.previousMeetingsInSummaryContextDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.menu)
        .disabled(!isEnabled)

        Toggle(isOn: $exportsToVault) {
            Text(L10n.exportBatchSummaryToVault)
            Text(L10n.exportBatchSummaryToVaultDescription)
        }
        .toggleStyle(.checkbox)
        .disabled(!isEnabled)

        Toggle(isOn: $exportsToGoogleDocs) {
            Text(L10n.exportBatchSummaryToGoogleDocs)
            Text(L10n.exportBatchSummaryToGoogleDocsDescription)
        }
        .toggleStyle(.checkbox)
        .disabled(!isEnabled)
    }
}
