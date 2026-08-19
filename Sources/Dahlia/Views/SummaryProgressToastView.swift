import SwiftUI

/// 要約生成時に右下に表示するミーティング別の進捗一覧。
struct SummaryProgressToastView: View {
    let jobs: [SummaryGenerationJob]
    let onDismiss: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(L10n.runningTasks)
                        .font(.body)
                        .bold()
                        .foregroundStyle(DahliaDesign.primaryTextColor)

                    Text(jobs.count, format: .number)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.runningTasks)
                .accessibilityValue(jobs.count.formatted())

                Spacer(minLength: 8)

                Button {
                    setExpanded(!isExpanded)
                } label: {
                    Label(
                        isExpanded ? L10n.collapse : L10n.expand,
                        systemImage: isExpanded ? "minus" : "chevron.up"
                    )
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .help(isExpanded ? L10n.collapse : L10n.expand)
            }

            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(jobs) { job in
                            SummaryGenerationJobProgressView(job: job, onDismiss: onDismiss)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 360)
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .onChange(of: jobs.map(\.id)) { oldIDs, newIDs in
            guard !isExpanded, newIDs.contains(where: { !oldIDs.contains($0) }) else { return }
            setExpanded(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if reduceMotion {
            isExpanded = expanded
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = expanded
            }
        }
    }
}

private struct SummaryGenerationJobProgressView: View {
    let job: SummaryGenerationJob
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.meetingName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if job.hasFailure, job.isFinished {
                    Button(L10n.close, systemImage: "xmark", action: { onDismiss(job.id) })
                        .labelStyle(.iconOnly)
                        .dahliaFixedSymbol()
                        .buttonStyle(.plain)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }

            if !job.progress.transcription.isSkipped {
                SummaryProgressStepRow(
                    label: L10n.transcription,
                    status: job.progress.transcription,
                    progress: job.progress.transcriptionProgress,
                    showsProgressBar: true
                )
            }
            SummaryProgressStepRow(label: L10n.generateSummary, status: job.progress.summaryGeneration)
            if !job.progress.vaultExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToVault, status: job.progress.vaultExport)
            }
            if !job.progress.googleDocsExport.isSkipped {
                SummaryProgressStepRow(label: L10n.exportBatchSummaryToGoogleDocs, status: job.progress.googleDocsExport)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: DahliaDesign.Card.compactCornerRadius)
        )
    }
}
