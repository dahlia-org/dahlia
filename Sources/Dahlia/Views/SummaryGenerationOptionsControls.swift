import SwiftUI

struct SummaryGenerationOptionsControls: View {
    @Binding var exportsToVault: Bool
    @Binding var exportsToGoogleDocs: Bool
    let isEnabled: Bool

    var body: some View {
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
