import DahliaRuntimeSupport
import Foundation

enum SummaryTextSelectionRows {
    static func rows(for document: SummaryDocument) -> [(id: String, text: String)] {
        var rows: [(id: String, text: String)] = []
        func append(_ id: String, _ text: String, isCode: Bool = false) {
            guard !text.isEmpty else { return }
            let plain = isCode ? text : String(((try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)).characters)
            rows.append((id, plain))
        }
        for section in document.sections {
            append(section.id.uuidString, section.heading)
            for block in section.blocks {
                let id = block.id.uuidString
                switch block.content {
                case let .paragraph(text), let .quote(text), let .heading(_, text), let .image(_, text):
                    append(id, text.text)
                case let .code(_, text):
                    append(id, text.text, isCode: true)
                case let .bulletedList(items), let .numberedList(items):
                    for (index, item) in items.enumerated() {
                        append("\(id)-\(index)", item.text)
                    }
                case let .checklist(items):
                    for (index, item) in items.enumerated() {
                        append("\(id)-\(index)", item.text.text)
                    }
                case let .table(headers, cells):
                    for (column, header) in headers.enumerated() {
                        append("\(id)-header-\(column)", header.text)
                    }
                    for (index, row) in cells.enumerated() {
                        for (column, cell) in row.enumerated() {
                            append("\(id)-\(index)-\(column)", cell.text)
                        }
                    }
                }
            }
        }
        let items = document.actionItems.filter { $0.title.nilIfBlank != nil }
        if !items.isEmpty { append("actions", L10n.actionItems) }
        for (index, item) in items.enumerated() {
            append("action-\(index)", item.title)
            if let assignee = item.assignee.nilIfBlank { append("assignee-\(index)", "(\(assignee))", isCode: true) }
        }
        return rows
    }
}
