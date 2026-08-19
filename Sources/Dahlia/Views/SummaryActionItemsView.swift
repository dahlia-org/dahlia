import DahliaRuntimeSupport
import SwiftUI

struct SummaryActionItemsView: View {
    let actionItems: [SummaryActionItem]

    var body: some View {
        let displayableItems = actionItems.filter { $0.title.nilIfBlank != nil }

        if !displayableItems.isEmpty {
            VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
                Text(L10n.actionItems)
                    .font(.title2)
                    .bold()
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: DahliaDesign.listItemSpacing) {
                    ForEach(displayableItems.enumerated(), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "square")
                                .dahliaFixedSymbol()
                                .foregroundStyle(DahliaDesign.optionalTextColor)
                                .accessibilityHidden(true)

                            Text(inlineMarkdown(item.title))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(DahliaDesign.paragraphLineSpacing)

                            if let assignee = item.assignee.nilIfBlank {
                                Text("(\(assignee))")
                                    .font(.callout)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
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
