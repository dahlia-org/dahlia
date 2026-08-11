import SwiftUI

struct SummaryProgressStepRow: View {
    let label: String
    let status: SummaryProgressState.StepStatus
    var progress: Double?
    var showsProgressBar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Group {
                    switch status {
                    case .pending:
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    case .running:
                        ProgressView()
                            .controlSize(.mini)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .skipped:
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.tertiary)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(textColor)
            }

            if let failureMessage = status.failureMessage {
                Text(failureMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }

            if case .running = status, showsProgressBar {
                Group {
                    if let progress {
                        ProgressView(value: progress, total: 1)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .padding(.leading, 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var textColor: Color {
        switch status {
        case .pending: .secondary
        case .running: .primary
        case .completed, .skipped: .secondary
        case .failed: .red
        }
    }

    private var accessibilityValue: String {
        guard case .running = status,
              let progress else {
            return status.accessibilityDescription
        }
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }
}
