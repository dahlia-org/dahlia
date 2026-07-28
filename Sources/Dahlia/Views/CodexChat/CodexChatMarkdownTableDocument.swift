import AppKit

extension CodexChatMarkdownTextDocument {
    static func appendTable(
        _ renderedTable: CodexChatMarkdownRenderedTable,
        to document: NSMutableAttributedString
    ) {
        let rows = [renderedTable.header] + renderedTable.rows
        guard let columnCount = rows.first?.count, columnCount > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = true

        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0 ..< columnCount {
                let location = document.length
                document.append(NSAttributedString(row[columnIndex]))
                let isLastCell = rowIndex == rows.count - 1
                    && columnIndex == columnCount - 1
                if !isLastCell {
                    let separator = columnIndex == columnCount - 1 ? "\n" : "\t"
                    document.append(NSAttributedString(
                        string: "\n",
                        attributes: [copyReplacementAttribute: separator]
                    ))
                }

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
                style.alignment = textAlignment(renderedTable.alignments[columnIndex])
                document.addAttribute(.paragraphStyle, value: style, range: range)
                applyBodyFont(to: document, range: range)
                if rowIndex == 0 {
                    let font = NSFont.preferredFont(forTextStyle: .body)
                    document.addAttribute(
                        .font,
                        value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                        range: range
                    )
                }
            }
        }
    }

    private static func textAlignment(
        _ alignment: CodexChatMarkdownTableAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
