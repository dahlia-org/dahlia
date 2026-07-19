import Foundation

enum CodexChatMarkdownParser {
    static func parse(_ markdown: String) throws -> [CodexChatMarkdownBlock] {
        try Task.checkCancellation()
        let normalizedLineEndings = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        try Task.checkCancellation()
        let normalized = normalizedLineEndings.replacingOccurrences(of: "\r", with: "\n")
        try Task.checkCancellation()
        let lines = normalized.components(separatedBy: "\n")
        try Task.checkCancellation()
        var blocks: [CodexChatMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            try Task.checkCancellation()
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let block = try parseFence(lines, index: &index) {
                blocks.append(block)
            } else if let block = parseHeading(lines[index]) {
                blocks.append(block)
                index += 1
            } else if isDivider(lines[index]) {
                blocks.append(.divider)
                index += 1
            } else if isBlockquote(lines[index]) {
                try blocks.append(parseBlockquote(lines, index: &index))
            } else if let marker = listMarker(in: lines[index]) {
                try blocks.append(parseList(lines, index: &index, kind: marker.kind))
            } else {
                try blocks.append(parseParagraph(lines, index: &index))
            }
        }

        return blocks
    }

    private enum ListKind: Equatable {
        case unordered
        case ordered
    }

    private struct ListMarker {
        let kind: ListKind
        let orderedMarker: String?
        let content: String
    }

    private static func parseFence(
        _ lines: [String],
        index: inout Int
    ) throws -> CodexChatMarkdownBlock? {
        let opening = lines[index].trimmingCharacters(in: .whitespaces)
        guard opening.hasPrefix("```") else { return nil }

        let language = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1
        var codeLines: [String] = []
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            try Task.checkCancellation()
            codeLines.append(lines[index])
            index += 1
        }
        if index < lines.count {
            index += 1
        }

        return .code(
            language: language.isEmpty ? nil : language,
            text: codeLines.joined(separator: "\n")
        )
    }

    private static func parseHeading(_ line: String) -> CodexChatMarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(level),
              trimmed.dropFirst(level).first == " "
        else { return nil }

        return .heading(
            level: level,
            text: String(trimmed.dropFirst(level + 1))
        )
    }

    private static func parseBlockquote(
        _ lines: [String],
        index: inout Int
    ) throws -> CodexChatMarkdownBlock {
        var quoteLines: [String] = []
        while index < lines.count, isBlockquote(lines[index]) {
            try Task.checkCancellation()
            let trimmed = removingLeadingWhitespace(from: lines[index])
            quoteLines.append(removingLeadingWhitespace(from: String(trimmed.dropFirst())))
            index += 1
        }
        return .blockquote(joinedText(quoteLines))
    }

    private static func parseList(
        _ lines: [String],
        index: inout Int,
        kind: ListKind
    ) throws -> CodexChatMarkdownBlock {
        var items: [String] = []
        var orderedItems: [CodexChatMarkdownOrderedItem] = []

        while index < lines.count {
            try Task.checkCancellation()
            guard let marker = listMarker(in: lines[index]), marker.kind == kind else { break }
            var itemLines = [marker.content]
            index += 1

            while index < lines.count {
                try Task.checkCancellation()
                if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let next = nextNonemptyLine(in: lines, after: index)
                    if let next,
                       let nextMarker = listMarker(in: lines[next]),
                       nextMarker.kind == kind {
                        index = next
                    }
                    break
                }
                if listMarker(in: lines[index]) != nil || isBlockStart(lines[index]) {
                    break
                }
                itemLines.append(removingLeadingWhitespace(from: lines[index]))
                index += 1
            }

            let text = joinedText(itemLines)
            if let orderedMarker = marker.orderedMarker {
                orderedItems.append(CodexChatMarkdownOrderedItem(marker: orderedMarker, text: text))
            } else {
                items.append(text)
            }
        }

        switch kind {
        case .unordered:
            return .unorderedList(items)
        case .ordered:
            return .orderedList(orderedItems)
        }
    }

    private static func parseParagraph(
        _ lines: [String],
        index: inout Int
    ) throws -> CodexChatMarkdownBlock {
        var paragraphLines: [String] = []
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            try Task.checkCancellation()
            if !paragraphLines.isEmpty, isBlockStart(lines[index]) {
                break
            }
            paragraphLines.append(lines[index])
            index += 1
        }
        return .paragraph(joinedText(paragraphLines))
    }

    private static func joinedText(_ lines: [String]) -> String {
        lines.enumerated().reduce(into: "") { result, element in
            let (offset, line) = element
            let hasHardBreak = line.hasSuffix("  ")
            result += hasHardBreak ? String(line.dropLast(2)) : line
            if offset < lines.count - 1 {
                result += hasHardBreak ? "\n" : " "
            }
        }
    }

    private static func listMarker(in line: String) -> ListMarker? {
        let trimmed = removingLeadingWhitespace(from: line)
        if let first = trimmed.first,
           ["-", "*", "+"].contains(first),
           trimmed.dropFirst().first == " " {
            return ListMarker(
                kind: .unordered,
                orderedMarker: nil,
                content: String(trimmed.dropFirst(2))
            )
        }

        let number = trimmed.prefix(while: { $0.isNumber })
        guard !number.isEmpty else { return nil }
        let suffix = trimmed.dropFirst(number.count)
        guard let punctuation = suffix.first,
              punctuation == "." || punctuation == ")",
              suffix.dropFirst().first == " "
        else { return nil }
        return ListMarker(
            kind: .ordered,
            orderedMarker: String(number) + String(punctuation),
            content: String(suffix.dropFirst(2))
        )
    }

    private static func nextNonemptyLine(in lines: [String], after index: Int) -> Int? {
        var candidate = index + 1
        while candidate < lines.count {
            if !lines[candidate].trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    private static func removingLeadingWhitespace(from line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isBlockStart(_ line: String) -> Bool {
        parseHeading(line) != nil ||
            isDivider(line) ||
            isBlockquote(line) ||
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```") ||
            listMarker(in: line) != nil
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(marker) && compact.allSatisfy { $0 == marker }
    }
}
