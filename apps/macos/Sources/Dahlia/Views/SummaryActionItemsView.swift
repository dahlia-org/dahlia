import AppKit
import DahliaRuntimeSupport
import SwiftUI

struct SummaryActionItemsView: View {
    let actionItems: [SummaryActionItem]
    let selection: TextSelectionGroup

    var body: some View {
        let displayableItems = actionItems.filter { $0.title.nilIfBlank != nil }

        if !displayableItems.isEmpty {
            VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
                SelectableSummaryText(
                    text: L10n.actionItems,
                    id: "actions",
                    selection: selection,
                    font: .boldSystemFont(ofSize: DahliaTypography.size(offset: 3))
                )
                .font(.dahliaTitle2)
                .bold()
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: DahliaDesign.listItemSpacing) {
                    ForEach(displayableItems.enumerated(), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "square")
                                .dahliaFixedSymbol()
                                .foregroundStyle(DahliaDesign.optionalTextColor)
                                .accessibilityHidden(true)

                            SelectableSummaryText(text: item.title, id: "action-\(index)", selection: selection)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(DahliaDesign.paragraphLineSpacing)

                            if let assignee = item.assignee.nilIfBlank {
                                SelectableSummaryText(
                                    text: "(\(assignee))",
                                    id: "assignee-\(index)",
                                    selection: selection,
                                    color: DahliaDesign.secondaryTextNSColor,
                                    isCode: true
                                )
                                .fixedSize(horizontal: true, vertical: true)
                                .font(.dahliaBody)
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                        }
                        .font(.dahliaBody)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

}
