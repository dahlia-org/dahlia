import SwiftUI

/// Marks where Pi summarized the conversation; earlier messages stay visible but reach the model only as the summary.
struct CodexChatCompactionDivider: View {
    /// nil while the summary is being written.
    let compaction: CodexChatCompaction?

    var body: some View {
        HStack(spacing: CodexChatDesign.contextDividerSpacing) {
            line
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text(title)
                if compaction == nil {
                    ProgressView().controlSize(.mini)
                }
            }
            .lineLimit(1)
            .fixedSize()
            line
        }
        .font(.system(size: DahliaTypography.size(offset: -4)))
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    var title: String {
        guard let compaction else { return L10n.chatCompacting }
        return L10n.chatCompacted(from: Self.tokens(compaction.tokensBefore), to: Self.tokens(compaction.tokensAfter))
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }
}
