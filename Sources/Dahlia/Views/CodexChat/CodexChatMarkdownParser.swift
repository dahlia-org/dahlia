import Foundation

enum CodexChatMarkdownParser {
    static func parse(_ markdown: String) throws -> [CodexChatMarkdownBlock] {
        try parseTrackingUnstableTail(markdown).blocks
    }

    static func parseTrackingUnstableTail(_ markdown: String) throws -> CodexChatMarkdownParseResult {
        try Task.checkCancellation()
        let normalizedLineEndings = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        try Task.checkCancellation()
        let normalized = normalizedLineEndings.replacingOccurrences(of: "\r", with: "\n")
        try Task.checkCancellation()
        let lines = normalized.components(separatedBy: "\n")
        try Task.checkCancellation()
        var blocks: [CodexChatMarkdownBlock] = []
        var blockStartLineIndices: [Int] = []
        var index = 0

        while index < lines.count {
            try Task.checkCancellation()
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            blockStartLineIndices.append(index)

            if let block = try parseFence(lines, index: &index) {
                blocks.append(block)
            } else if let block = try parseTable(lines, index: &index) {
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

        return try makeParseResult(
            markdown: markdown,
            lines: lines,
            blocks: blocks,
            blockStartLineIndices: blockStartLineIndices
        )
    }
}

private extension CodexChatMarkdownParser {
    static func makeParseResult(
        markdown: String,
        lines: [String],
        blocks: [CodexChatMarkdownBlock],
        blockStartLineIndices: [Int]
    ) throws -> CodexChatMarkdownParseResult {
        guard let finalBlockStartLine = blockStartLineIndices.last else {
            return CodexChatMarkdownParseResult(
                blocks: blocks,
                stablePrefixBlockCount: 0,
                reparseSource: markdown
            )
        }

        let includesPreviousBlock = shouldIncludePreviousBlock(
            lines: lines,
            blocks: blocks,
            finalBlockStartLine: finalBlockStartLine
        )
        let reparseBlockIndex = includesPreviousBlock ? blocks.count - 2 : blocks.count - 1
        let reparseStartLine = blockStartLineIndices[reparseBlockIndex]
        let sourceStartIndex = try sourceStartIndex(
            ofLine: reparseStartLine,
            in: markdown
        )
        return CodexChatMarkdownParseResult(
            blocks: blocks,
            stablePrefixBlockCount: reparseBlockIndex,
            reparseSource: String(markdown[sourceStartIndex...])
        )
    }

    static func shouldIncludePreviousBlock(
        lines: [String],
        blocks: [CodexChatMarkdownBlock],
        finalBlockStartLine: Int
    ) -> Bool {
        guard blocks.count > 1,
              finalBlockStartLine == lines.count - 1
        else { return false }

        let finalLine = lines[finalBlockStartLine]
        let precedingLine = lines[finalBlockStartLine - 1]
        let previousBlock = blocks[blocks.count - 2]
        let finalLineCanInvalidateItsBlockStart = !isAppendStableBlockStart(line: finalLine)
        let finalLineCanJoinPreviousTable = !precedingLine.trimmingCharacters(in: .whitespaces).isEmpty
            && previousBlock.isTable
        let finalLineCanCompleteTableDelimiter = canBecomeTableDelimiter(
            finalLine,
            forHeader: precedingLine
        )
        let finalLineCanJoinPreviousList = potentialListKind(afterAppendingTo: finalLine)
            .map { $0 == listKind(previousBlock) } ?? false

        return [
            finalLineCanInvalidateItsBlockStart,
            finalLineCanJoinPreviousTable,
            finalLineCanCompleteTableDelimiter,
            finalLineCanJoinPreviousList,
        ].contains(true)
    }

    enum ListKind: Equatable {
        case unordered
        case ordered
    }

    struct ListMarker {
        let kind: ListKind
        let orderedMarker: String?
        let content: String
    }

    static func parseFence(
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

    static func parseTable(
        _ lines: [String],
        index: inout Int
    ) throws -> CodexChatMarkdownBlock? {
        guard index + 1 < lines.count else { return nil }
        let header = tableCells(in: lines[index])
        let delimiterCells = tableCells(in: lines[index + 1])
        guard !header.isEmpty,
              delimiterCells.count == header.count,
              let alignments = tableAlignments(in: delimiterCells)
        else { return nil }

        index += 2
        var rows: [[String]] = []
        while index < lines.count {
            try Task.checkCancellation()
            let cells = tableCells(in: lines[index])
            guard !cells.isEmpty else { break }
            rows.append(normalizedTableRow(cells, columnCount: header.count))
            index += 1
        }

        return .table(CodexChatMarkdownTable(
            header: header,
            rows: rows,
            alignments: alignments
        ))
    }

    static func tableCells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }

        var cells: [String] = []
        var cell = ""
        var isEscaped = false
        var endsWithDelimiter = false
        for character in trimmed {
            if character == "|", !isEscaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                endsWithDelimiter = true
            } else {
                cell.append(character)
                endsWithDelimiter = false
            }
            isEscaped = character == "\\" && !isEscaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if trimmed.hasPrefix("|") {
            cells.removeFirst()
        }
        if endsWithDelimiter {
            cells.removeLast()
        }
        return cells
    }

    static func tableAlignments(
        in delimiterCells: [String]
    ) -> [CodexChatMarkdownTableAlignment]? {
        var alignments: [CodexChatMarkdownTableAlignment] = []
        for cell in delimiterCells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let hasLeadingColon = trimmed.hasPrefix(":")
            let hasTrailingColon = trimmed.hasSuffix(":")
            let rule = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard rule.count >= 3, rule.allSatisfy({ $0 == "-" }) else { return nil }
            let alignment: CodexChatMarkdownTableAlignment = if hasLeadingColon, hasTrailingColon {
                .center
            } else if hasTrailingColon {
                .right
            } else {
                .left
            }
            alignments.append(alignment)
        }
        return alignments
    }

    static func normalizedTableRow(
        _ cells: [String],
        columnCount: Int
    ) -> [String] {
        Array((cells + Array(repeating: "", count: columnCount)).prefix(columnCount))
    }

    static func parseHeading(_ line: String) -> CodexChatMarkdownBlock? {
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

    static func parseBlockquote(
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

    static func parseList(
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

    static func parseParagraph(
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

    static func joinedText(_ lines: [String]) -> String {
        lines.enumerated().reduce(into: "") { result, element in
            let (offset, line) = element
            let hasHardBreak = line.hasSuffix("  ")
            result += hasHardBreak ? String(line.dropLast(2)) : line
            if offset < lines.count - 1 {
                result += hasHardBreak ? "\n" : " "
            }
        }
    }

    static func listMarker(in line: String) -> ListMarker? {
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

    static func nextNonemptyLine(in lines: [String], after index: Int) -> Int? {
        var candidate = index + 1
        while candidate < lines.count {
            if !lines[candidate].trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    static func removingLeadingWhitespace(from line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    static func isBlockStart(_ line: String) -> Bool {
        parseHeading(line) != nil ||
            isDivider(line) ||
            isBlockquote(line) ||
            line.trimmingCharacters(in: .whitespaces).hasPrefix("```") ||
            listMarker(in: line) != nil
    }

    static func isBlockquote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(marker) && compact.allSatisfy { $0 == marker }
    }

    static func isAppendStableBlockStart(line: String) -> Bool {
        !isDivider(line)
    }

    static func canBecomeTableDelimiter(
        _ line: String,
        forHeader headerLine: String
    ) -> Bool {
        let header = tableCells(in: headerLine)
        guard !header.isEmpty else { return false }

        let candidate = line.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return false }
        return candidate.allSatisfy { character in
            character == "-"
                || character == ":"
                || character == "|"
                || character.isWhitespace
        }
    }

    static func potentialListKind(afterAppendingTo line: String) -> ListKind? {
        let trimmed = removingLeadingWhitespace(from: line)
        if trimmed.count == 1, let marker = trimmed.first,
           ["-", "*", "+"].contains(marker) {
            return .unordered
        }

        let number = trimmed.prefix(while: { $0.isNumber })
        guard !number.isEmpty else { return nil }
        let suffix = trimmed.dropFirst(number.count)
        guard suffix.isEmpty || suffix == "." || suffix == ")" else { return nil }
        return .ordered
    }

    static func listKind(_ block: CodexChatMarkdownBlock) -> ListKind? {
        switch block {
        case .unorderedList:
            .unordered
        case .orderedList:
            .ordered
        default:
            nil
        }
    }

    static func sourceStartIndex(
        ofLine targetLine: Int,
        in markdown: String
    ) throws -> String.Index {
        guard targetLine > 0 else { return markdown.startIndex }

        var line = 0
        var index = markdown.unicodeScalars.startIndex
        var scannedScalarCount = 0

        while index < markdown.unicodeScalars.endIndex {
            if scannedScalarCount.isMultiple(of: 1024) {
                try Task.checkCancellation()
            }
            scannedScalarCount += 1

            let scalar = markdown.unicodeScalars[index]
            index = markdown.unicodeScalars.index(after: index)
            guard scalar == "\r" || scalar == "\n" else { continue }

            if scalar == "\r",
               index < markdown.unicodeScalars.endIndex,
               markdown.unicodeScalars[index] == "\n" {
                index = markdown.unicodeScalars.index(after: index)
            }
            line += 1
            if line == targetLine {
                return index
            }
        }

        return markdown.endIndex
    }
}

private extension CodexChatMarkdownBlock {
    var isTable: Bool {
        if case .table = self { true } else { false }
    }
}
