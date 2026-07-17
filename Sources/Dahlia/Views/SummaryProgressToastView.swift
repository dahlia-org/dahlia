import SwiftUI

/// 要約生成時に右下に表示する進捗トースト。
struct SummaryProgressToastView: View {
    let state: SummaryProgressState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.generatingSummary)
                .font(.callout)
                .bold()
                .foregroundStyle(.primary)

            SummaryProgressStepRow(label: L10n.generateSummary, status: state.summaryGeneration)
            if !state.vaultExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToVault, status: state.vaultExport)
            }
            if !state.googleDocsExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToGoogleDocs, status: state.googleDocsExport)
            }
        }
        .padding(12)
        .frame(minWidth: 220)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}
