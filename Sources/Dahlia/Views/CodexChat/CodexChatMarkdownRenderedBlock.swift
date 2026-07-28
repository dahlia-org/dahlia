import Foundation

enum CodexChatMarkdownRenderedBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case unorderedList([AttributedString])
    case orderedList([CodexChatMarkdownRenderedOrderedItem])
    case blockquote(AttributedString)
    case table(CodexChatMarkdownRenderedTable)
    case code(language: String?, text: String)
    case divider

    var acceptsPendingSuffix: Bool {
        switch self {
        case let .unorderedList(items):
            !items.isEmpty
        case let .orderedList(items):
            !items.isEmpty
        case .divider, .table:
            false
        default:
            true
        }
    }

    func appendingPendingSuffix(_ suffix: String) -> Self? {
        let attributedSuffix = AttributedString(suffix)
        switch self {
        case var .paragraph(text):
            text.append(attributedSuffix)
            return .paragraph(text)
        case let .heading(level, originalText):
            var text = originalText
            text.append(attributedSuffix)
            return .heading(level: level, text: text)
        case var .unorderedList(items):
            guard let lastIndex = items.indices.last else { return nil }
            items[lastIndex].append(attributedSuffix)
            return .unorderedList(items)
        case var .orderedList(items):
            guard let lastIndex = items.indices.last else { return nil }
            let item = items[lastIndex]
            var text = item.text
            text.append(attributedSuffix)
            items[lastIndex] = CodexChatMarkdownRenderedOrderedItem(marker: item.marker, text: text)
            return .orderedList(items)
        case var .blockquote(text):
            text.append(attributedSuffix)
            return .blockquote(text)
        case .table:
            return nil
        case let .code(language, text):
            return .code(language: language, text: text + suffix)
        case .divider:
            return nil
        }
    }
}

struct CodexChatMarkdownRenderedTable: Equatable, Sendable {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [CodexChatMarkdownTableAlignment]
}
