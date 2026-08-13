import AppKit
import DahliaRuntimeSupport

extension SummaryAttributedDocument {
    static func appendTable(
        headers: [SummaryText],
        rows: [[SummaryText]],
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }
        beginBlock(in: document)

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true
        let allRows = [headers] + rows

        for (rowIndex, row) in allRows.enumerated() {
            for columnIndex in 0 ..< columnCount {
                let location = document.length
                let cellText = row.indices.contains(columnIndex) ? row[columnIndex] : SummaryText("")
                appendInlineMarkdown(cellText.text, to: document)
                appendTranscriptReference(
                    cellText.transcriptRef,
                    to: document,
                    transcriptTextProvider: transcriptTextProvider,
                    allowsPopover: allowsTranscriptReferencePopovers
                )

                let isLastColumn = columnIndex == columnCount - 1
                let isLastCell = rowIndex == allRows.count - 1 && isLastColumn
                let copySeparator = if isLastCell {
                    ""
                } else if isLastColumn {
                    "\n"
                } else {
                    "\t"
                }
                document.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        SummarySelectableNSTextView.copyReplacementAttribute: copySeparator,
                    ]
                ))

                let range = NSRange(location: location, length: document.length - location)
                let cell = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 {
                    cell.backgroundColor = .controlBackgroundColor
                }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.paragraphSpacing = isLastCell ? DahliaDesign.blockSpacing : 0
                document.addAttributes([
                    .font: rowIndex == 0
                        ? boldFont(for: .caption1)
                        : NSFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ], range: range)
            }
        }
    }
}
