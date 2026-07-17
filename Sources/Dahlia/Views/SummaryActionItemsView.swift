import SwiftUI

struct SummaryActionItemsView: View {
    let actionItems: [SummaryActionItem]

    var body: some View {
        let displayableItems = actionItems.filter { $0.title.nilIfBlank != nil }

        if !displayableItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.actionItems)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(displayableItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "square")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)

                            Text(inlineMarkdown(item.title))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)

                            if let assignee = item.assignee.nilIfBlank {
                                Text("(\(assignee))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.body)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
