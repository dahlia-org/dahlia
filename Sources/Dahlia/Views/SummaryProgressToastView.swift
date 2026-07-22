import SwiftUI

/// 要約生成時に右下に表示するミーティング別の進捗一覧。
struct SummaryProgressToastView: View {
    let jobs: [SummaryGenerationJob]
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.runningTasks)
                .font(.callout)
                .bold()
                .foregroundStyle(.primary)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(jobs) { job in
                        SummaryGenerationJobProgressView(job: job, onDismiss: onDismiss)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 360)
        }
        .padding(12)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

private struct SummaryGenerationJobProgressView: View {
    let job: SummaryGenerationJob
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.meetingName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if job.hasFailure, job.isFinished {
                    Button(L10n.close, systemImage: "xmark", action: { onDismiss(job.id) })
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            SummaryProgressStepRow(label: L10n.generateSummary, status: job.progress.summaryGeneration)
            if !job.progress.vaultExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToVault, status: job.progress.vaultExport)
            }
            if !job.progress.googleDocsExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToGoogleDocs, status: job.progress.googleDocsExport)
            }
            ForEach(Array(Set(job.failureMessages)).sorted(), id: \.self) { message in
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}
