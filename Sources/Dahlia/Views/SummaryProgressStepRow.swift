import SwiftUI

struct SummaryProgressStepRow: View {
    let label: String
    let status: SummaryProgressState.StepStatus

    var body: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(status.accessibilityDescription)
    }

    private var textColor: Color {
        switch status {
        case .pending: .secondary
        case .running: .primary
        case .completed, .skipped: .secondary
        case .failed: .red
        }
    }
}
