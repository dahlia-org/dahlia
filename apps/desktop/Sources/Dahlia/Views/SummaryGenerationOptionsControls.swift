import SwiftUI

struct SummaryGenerationOptionsControls: View {
    @Binding var detailLevel: SummaryDetailLevel?
    @Binding var exportsToWorkspace: Bool
    @Binding var exportsToGoogleDocs: Bool
    let isEnabled: Bool
    let usesServerSummary: Bool

    var body: some View {
        Picker(selection: $detailLevel) {
            Text(L10n.workspaceGenerationDefault).tag(SummaryDetailLevel?.none)
            ForEach(SummaryDetailLevel.allCases) { level in
                Text(level.displayName).tag(Optional(level))
            }
        } label: {
            Text(L10n.summaryDetailLevel)
            Text(L10n.summaryDetailLevelDescription)
        }
        .pickerStyle(.menu)
        .disabled(!isEnabled)

        if !usesServerSummary {
            Toggle(isOn: $exportsToWorkspace) {
                Text(L10n.exportBatchSummaryToWorkspace)
                Text(L10n.exportBatchSummaryToWorkspaceDescription)
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
