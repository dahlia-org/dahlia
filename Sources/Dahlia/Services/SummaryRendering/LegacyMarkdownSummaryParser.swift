import Foundation

enum LegacyMarkdownSummaryParser {
    static func parse(
        markdown: String,
        title: String = "",
        context: SummaryRenderContext? = nil
    ) -> SummaryDocument {
        let lines = bodyWithoutFrontmatter(markdown).components(separatedBy: "\n")
        var sections: [SummarySection] = []
        var currentSection = SummarySection(id: .v7(), heading: "", blocks: [])
        var i = 0

        func finishCurrentSection() {
            guard !currentSection.heading.isEmpty || !currentSection.blocks.isEmpty else { return }
            sections.append(currentSection)
            currentSection = SummarySection(id: .v7(), heading: "", blocks: [])
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count {
                    i += 1
                }
                currentSection.blocks.append(.code(language: language, code: codeLines.joined(separator: "\n")))
                continue
            }

            if isHorizontalRule(trimmed) {
                i += 1
                continue
            }

            if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                let level = match.1.count
                let parsed = inlineTextAndImages(String(match.2), context: context)
                if level <= 2 {
                    finishCurrentSection()
                    currentSection.heading = parsed.text.text
                    currentSection.blocks.append(contentsOf: parsed.images)
                } else {
                    if !parsed.text.text.isEmpty {
                        currentSection.blocks.append(.heading(level: level, content: parsed.text))
                    }
                    currentSection.blocks.append(contentsOf: parsed.images)
                }
                i += 1
                continue
            }

            if isTableStart(lines: lines, index: i) {
                var tableImages: [SummaryBlock] = []
                let headers = parsePipeRow(trimmed).map { text in
                    let parsed = inlineTextAndImages(text, context: context)
                    tableImages.append(contentsOf: parsed.images)
                    return parsed.text
                }
                i += 2
                var rows: [[SummaryText]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).contains("|") {
                    rows.append(parsePipeRow(lines[i]).map { text in
                        let parsed = inlineTextAndImages(text, context: context)
                        tableImages.append(contentsOf: parsed.images)
                        return parsed.text
                    })
                    i += 1
                }
                currentSection.blocks.append(.table(headers: headers, rows: rows))
                currentSection.blocks.append(contentsOf: tableImages)
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let content = lines[i].trimmingCharacters(in: .whitespaces)
                        .replacing(/^>\s?/, with: "")
                    quoteLines.append(content)
                    i += 1
                }
                let parsed = inlineTextAndImages(quoteLines.joined(separator: " "), context: context)
                if !parsed.text.text.isEmpty {
                    currentSection.blocks.append(.quote(parsed.text))
                }
                currentSection.blocks.append(contentsOf: parsed.images)
                continue
            }

            if let checklistMatch = checklistItem(in: trimmed) {
                var items: [SummaryBlock.ChecklistItem] = []
                var images: [SummaryBlock] = []
                let first = inlineTextAndImages(checklistMatch.text, context: context)
                images.append(contentsOf: first.images)
                if !first.text.text.isEmpty {
                    items.append(.init(text: first.text, checked: checklistMatch.checked))
                }
                i += 1
                while i < lines.count,
                      let next = checklistItem(in: lines[i].trimmingCharacters(in: .whitespaces)) {
                    let parsed = inlineTextAndImages(next.text, context: context)
                    images.append(contentsOf: parsed.images)
                    if !parsed.text.text.isEmpty {
                        items.append(.init(text: parsed.text, checked: next.checked))
                    }
                    i += 1
                }
                if !items.isEmpty {
                    currentSection.blocks.append(.checklist(items: items))
                }
                currentSection.blocks.append(contentsOf: images)
                continue
            }

            if let item = unorderedListItem(in: trimmed) {
                var images: [SummaryBlock] = []
                let first = inlineTextAndImages(item, context: context)
                images.append(contentsOf: first.images)
                var items = first.text.text.isEmpty ? [] : [first.text]
                i += 1
                while i < lines.count,
                      let next = unorderedListItem(in: lines[i].trimmingCharacters(in: .whitespaces)),
                      checklistItem(in: lines[i].trimmingCharacters(in: .whitespaces)) == nil {
                    let parsed = inlineTextAndImages(next, context: context)
                    images.append(contentsOf: parsed.images)
                    if !parsed.text.text.isEmpty {
                        items.append(parsed.text)
                    }
                    i += 1
                }
                if !items.isEmpty {
                    currentSection.blocks.append(.bulletedList(items: items))
                }
                currentSection.blocks.append(contentsOf: images)
                continue
            }

            if let item = orderedListItem(in: trimmed) {
                var images: [SummaryBlock] = []
                let first = inlineTextAndImages(item, context: context)
                images.append(contentsOf: first.images)
                var items = first.text.text.isEmpty ? [] : [first.text]
                i += 1
                while i < lines.count,
                      let next = orderedListItem(in: lines[i].trimmingCharacters(in: .whitespaces)) {
                    let parsed = inlineTextAndImages(next, context: context)
                    images.append(contentsOf: parsed.images)
                    if !parsed.text.text.isEmpty {
                        items.append(parsed.text)
                    }
                    i += 1
                }
                if !items.isEmpty {
                    currentSection.blocks.append(.numberedList(items: items))
                }
                currentSection.blocks.append(contentsOf: images)
                continue
            }

            var paragraphLines: [String] = []
            while i < lines.count {
                let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isBlockStart(candidate, lines: lines, index: i) {
                    break
                }
                paragraphLines.append(candidate)
                i += 1
            }
            let blocks = parseInlineBlocks(paragraphLines.joined(separator: " "), context: context)
            currentSection.blocks.append(contentsOf: blocks)
        }

        finishCurrentSection()
        return SummaryDocument(title: title, sections: sections, tags: [], actionItems: [])
    }

    static func parseInlineBlocks(_ text: String, context: SummaryRenderContext? = nil) -> [SummaryBlock] {
        let matches = obsidianImageEmbedRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else {
            let normalized = normalizedTextAndRefs(text)
            let paragraph = normalized.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return paragraph.isEmpty ? [] : [.paragraph(SummaryText(paragraph, transcriptRef: normalized.refs.first))]
        }

        var blocks: [SummaryBlock] = []
        var cursor = text.startIndex
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let targetRange = Range(match.range(at: 1), in: text) else { continue }

            let prefix = String(text[cursor ..< fullRange.lowerBound])
            appendParagraph(prefix, to: &blocks)

            let target = String(text[targetRange])
            let caption = if let aliasRange = Range(match.range(at: 2), in: text) {
                String(text[aliasRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                ""
            }
            let normalizedCaption = normalizedTextAndRefs(caption)
            if let screenshotId = resolvedScreenshotId(for: target, context: context) {
                blocks.append(.image(
                    screenshotId: screenshotId,
                    caption: SummaryText(normalizedCaption.text, transcriptRef: normalizedCaption.refs.first)
                ))
            } else if !normalizedCaption.text.isEmpty {
                appendParagraph(caption, to: &blocks)
            }

            cursor = fullRange.upperBound
        }

        appendParagraph(String(text[cursor...]), to: &blocks)
        return blocks
    }

    static func normalizeInlineMarkdown(_ text: String) -> String {
        normalizedTextAndRefs(text).text
    }

    static func normalizedTextAndRefs(_ text: String) -> (text: String, refs: [TranscriptReference]) {
        let markdownResult = replaceTranscriptMarkdownLinks(in: text)
        let obsidianResult = replaceObsidianLinks(in: markdownResult.text)
        return (
            text: cleanupReferenceWhitespace(obsidianResult.text),
            refs: uniqueReferences(markdownResult.refs + obsidianResult.refs)
        )
    }

    private static func replaceTranscriptMarkdownLinks(in text: String) -> (text: String, refs: [TranscriptReference]) {
        let matches = transcriptMarkdownLinkRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return (text, []) }

        var refs: [TranscriptReference] = []
        var normalized = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: normalized),
                  let labelRange = Range(match.range(at: 1), in: normalized),
                  let timeRange = Range(match.range(at: 2), in: normalized) else { continue }

            let label = String(normalized[labelRange])
            let time = String(normalized[timeRange])
            refs.append(TranscriptReference(time: time))
            normalized.replaceSubrange(fullRange, with: label == time ? "" : label)
        }

        return (normalized, Array(refs.reversed()))
    }

    private static func replaceObsidianLinks(in text: String) -> (text: String, refs: [TranscriptReference]) {
        let matches = obsidianLinkRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return (text, []) }

        var refs: [TranscriptReference] = []
        var normalized = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: normalized),
                  let targetRange = Range(match.range(at: 1), in: normalized) else { continue }

            let target = String(normalized[targetRange])
            let alias = Range(match.range(at: 2), in: normalized).map { String(normalized[$0]) }
            let parsed = transcriptReference(for: target, alias: alias)
            if let ref = parsed.ref {
                refs.append(ref)
            }
            let replacement = if let ref = parsed.ref, parsed.replacement == ref.time {
                ""
            } else {
                parsed.replacement
            }
            normalized.replaceSubrange(fullRange, with: replacement)
        }

        return (normalized, Array(refs.reversed()))
    }

    private static let obsidianImageEmbedRegex = try! NSRegularExpression(
        pattern: #"\!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    private static let transcriptMarkdownLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(transcript://([0-9]{2}:[0-9]{2}:[0-9]{2})\)"#
    )

    private static let obsidianLinkRegex = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    private static func bodyWithoutFrontmatter(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return markdown
        }

        let bodyStart = lines.index(after: closingIndex)
        guard bodyStart < lines.endIndex else { return "" }
        return lines[bodyStart...].joined(separator: "\n")
    }

    private static func appendParagraph(_ text: String, to blocks: inout [SummaryBlock]) {
        let normalized = normalizedTextAndRefs(text)
        let paragraph = normalized.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(SummaryText(paragraph, transcriptRef: normalized.refs.first)))
    }

    private static func inlineTextAndImages(_ text: String, context: SummaryRenderContext?) -> (
        text: SummaryText,
        images: [SummaryBlock]
    ) {
        var textParts: [String] = []
        var refs: [TranscriptReference] = []
        var images: [SummaryBlock] = []

        for block in parseInlineBlocks(text, context: context) {
            switch block.content {
            case let .paragraph(text):
                if !text.text.isEmpty {
                    textParts.append(text.text)
                    if let ref = text.transcriptRef {
                        refs.append(ref)
                    }
                }
            case .image:
                images.append(block)
            default:
                break
            }
        }

        return (
            text: SummaryText(textParts.joined(separator: " "), transcriptRef: uniqueReferences(refs).first),
            images: images
        )
    }

    private static func resolvedScreenshotId(for target: String, context: SummaryRenderContext?) -> UUID? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let component = (trimmed as NSString).lastPathComponent as NSString
        let stem = component.deletingPathExtension
        guard let id = UUID(uuidString: stem) else { return nil }

        if let context, !context.screenshots.contains(where: { $0.id == id }) {
            return nil
        }
        return id
    }

    private static func transcriptReference(for target: String, alias: String?) -> (replacement: String, ref: TranscriptReference?) {
        guard let hashIndex = target.lastIndex(of: "#") else {
            return (alias?.nilIfBlank ?? target, nil)
        }
        let timestamp = String(target[target.index(after: hashIndex)...])
        guard timestamp.firstMatch(of: /^\d{2}:\d{2}:\d{2}$/) != nil else {
            return (alias?.nilIfBlank ?? target, nil)
        }
        let label = alias?.nilIfBlank ?? timestamp
        return (label, TranscriptReference(time: timestamp))
    }

    private static func cleanupReferenceWhitespace(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"(^|[ \t])\([ \t]*\)"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueReferences(_ refs: [TranscriptReference]) -> [TranscriptReference] {
        var seen: Set<String> = []
        return refs.filter { ref in
            let key = ref.time
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func isBlockStart(_ line: String, lines: [String], index: Int) -> Bool {
        line.hasPrefix("```")
            || isHorizontalRule(line)
            || line.firstMatch(of: /^#{1,6}\s+.+$/) != nil
            || isTableStart(lines: lines, index: index)
            || line.hasPrefix(">")
            || checklistItem(in: line) != nil
            || unorderedListItem(in: line) != nil
            || orderedListItem(in: line) != nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.allSatisfy { $0 == "-" || $0 == " " } && line.count(where: { $0 == "-" }) >= 3
    }

    private static func isTableStart(lines: [String], index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return header.contains("|")
            && separator.contains("|")
            && separator.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            .isEmpty
            && separator.contains("-")
    }

    private static func checklistItem(in line: String) -> (text: String, checked: Bool)? {
        guard let match = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.+)$/) else { return nil }
        let marker = String(match.1)
        return (String(match.2), marker.lowercased() == "x")
    }

    private static func unorderedListItem(in line: String) -> String? {
        guard let match = line.firstMatch(of: /^[-*+]\s+(.+)$/) else { return nil }
        return String(match.1)
    }

    private static func orderedListItem(in line: String) -> String? {
        guard let match = line.firstMatch(of: /^\d+\.\s+(.+)$/) else { return nil }
        return String(match.1)
    }

    private static func parsePipeRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var index = line.startIndex
        var obsidianLinkDepth = 0

        while index < line.endIndex {
            let nextIndex = line.index(after: index)
            let character = line[index]
            if character == "[", nextIndex < line.endIndex, line[nextIndex] == "[" {
                obsidianLinkDepth += 1
                current.append(character)
                current.append(line[nextIndex])
                index = line.index(after: nextIndex)
                continue
            }
            if character == "]", nextIndex < line.endIndex, line[nextIndex] == "]", obsidianLinkDepth > 0 {
                obsidianLinkDepth -= 1
                current.append(character)
                current.append(line[nextIndex])
                index = line.index(after: nextIndex)
                continue
            }
            if character == "|", obsidianLinkDepth == 0 {
                let cell = current.trimmingCharacters(in: .whitespaces)
                if !cell.isEmpty {
                    cells.append(cell)
                }
                current = ""
            } else {
                current.append(character)
            }
            index = nextIndex
        }

        let cell = current.trimmingCharacters(in: .whitespaces)
        if !cell.isEmpty {
            cells.append(cell)
        }
        return cells
    }
}
