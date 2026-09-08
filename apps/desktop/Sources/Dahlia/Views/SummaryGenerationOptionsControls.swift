import SwiftUI

struct SummaryGenerationOptionsControls: View {
    @Binding var detailLevel: SummaryDetailLevel?
    @Binding var exportsToVault: Bool
    @Binding var exportsToGoogleDocs: Bool
    let isEnabled: Bool

    var body: some View {
        Picker(selection: $detailLevel) {
            if AppSettings.shared.currentVault?.accountConnectionId != nil || detailLevel == nil {
                Text(L10n.serverSummaryAccountDefault).tag(SummaryDetailLevel?.none)
            }
            ForEach(SummaryDetailLevel.allCases) { level in
                Text(level.displayName).tag(Optional(level))
            }
        } label: {
            Text(L10n.summaryDetailLevel)
            Text(L10n.summaryDetailLevelDescription)
        }
        .pickerStyle(.menu)
        .disabled(!isEnabled)

        if AppSettings.shared.currentVault?.accountConnectionId == nil {
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
        } else {
            Text(L10n.serverSummaryDescription).foregroundStyle(.secondary)
        }
    }
}
