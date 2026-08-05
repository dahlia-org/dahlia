import DahliaRuntimeSupport
import Foundation

extension SummaryShareRenderer {
    enum HTMLListKind {
        case bulleted
        case numbered

        var element: String {
            switch self {
            case .bulleted:
                "ul"
            case .numbered:
                "ol"
            }
        }
    }

    static func htmlList(
        _ items: [SummaryListItem],
        kind: HTMLListKind,
        destination: Destination
    ) -> String? {
        let renderedItems = items.compactMap { item -> (text: String, item: SummaryListItem)? in
            normalizedInlineMarkdown(item.text.text).nilIfBlank.map {
                (text: renderInlineHTML($0), item: item)
            }
        }
        guard !renderedItems.isEmpty else { return nil }
        let htmlItems = renderedItems.map { (text: $0.text, indent: $0.item.indent) }

        switch destination {
        case .googleDocs:
            return nestedHTMLList(htmlItems, element: kind.element)
        case .slack:
            let markers: [String] = switch kind {
            case .bulleted:
                Array(repeating: "•", count: renderedItems.count)
            case .numbered:
                SummaryListNumbering.numbers(for: renderedItems.map(\.item)).map { "\($0)." }
            }
            return slackHTMLList(items: htmlItems, markers: markers)
        }
    }

    static func htmlChecklist(_ items: [SummaryBlock.ChecklistItem], destination: Destination) -> String? {
        let renderedItems = items.compactMap { item -> (text: String, indent: Int)? in
            normalizedInlineMarkdown(item.text.text).nilIfBlank.map {
                (text: renderInlineHTML($0), indent: item.indent)
            }
        }
        guard !renderedItems.isEmpty else { return nil }

        switch destination {
        case .googleDocs:
            return nestedHTMLList(renderedItems, element: "ul")
        case .slack:
            return slackHTMLList(
                items: renderedItems,
                markers: Array(repeating: "•", count: renderedItems.count)
            )
        }
    }

    private static func nestedHTMLList(_ items: [(text: String, indent: Int)], element: String) -> String {
        var html = "<\(element)>\n"
        var currentIndent = 0

        for (index, item) in items.enumerated() {
            if index == 0 {
                html += "<li>\(item.text)"
            } else if item.indent > currentIndent {
                html += "\n<\(element)>\n<li>\(item.text)"
            } else if item.indent == currentIndent {
                html += "</li>\n<li>\(item.text)"
            } else {
                html += "</li>\n"
                for _ in item.indent ..< currentIndent {
                    html += "</\(element)>\n</li>\n"
                }
                html += "<li>\(item.text)"
            }
            currentIndent = item.indent
        }

        html += "</li>\n"
        for _ in 0 ..< currentIndent {
            html += "</\(element)>\n</li>\n"
        }
        return html + "</\(element)>"
    }

    private static func slackHTMLList(items: [(text: String, indent: Int)], markers: [String]) -> String {
        zip(items, markers).map { item, marker in
            String(repeating: "&nbsp;", count: item.indent * 4) + "\(marker) \(item.text)"
        }
        .joined(separator: "<br>\n")
    }
}
