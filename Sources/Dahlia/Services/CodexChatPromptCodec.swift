import Foundation

enum CodexChatPromptCodec {
    private static let contextStart = "<context>\n"
    private static let contextEnd = "</context>\n\n"
    private static let contextClosingTag = "</context>"
    private static let meetingDescription = "  You are viewing a meeting in the Dahlia App.\n"
    private static let meetingDraftDescription = "  You are viewing an unsaved meeting draft in the Dahlia App.\n"
    private static let liveModeDescription = "  Live mode is enabled. You are receiving finalized live transcription from Dahlia."
    private static let hiddenLiveTranscriptDescription = "  This turn contains one hidden live transcript block."
    private static let liveTranscriptStart = "<live_transcript>"
    private static let dahliaLiveTranscriptStart = "<live_transcript source=\"dahlia\">"
    private static let liveTranscriptEnd = "</live_transcript>"

    static func encode(text: String, context: CodexChatContext?) -> String {
        guard let context else { return text }
        return encodeContext(context) + "\n\n" + text
    }

    static func encodeTextBlocks(text: String, context: CodexChatContext?) -> [String] {
        guard let context else { return [text] }
        return [encodeContext(context), text]
    }

    static func encodeTextBlocks(
        text: String?,
        context: CodexChatContext?,
        includesLiveModeContext: Bool,
        liveTranscript: String? = nil
    ) -> [String] {
        let liveTranscript = liveTranscript?.nilIfBlank
        var blocks: [String] = []
        if context != nil || includesLiveModeContext {
            blocks.append(encodeContext(
                context,
                isLiveMode: includesLiveModeContext,
                containsLiveTranscript: liveTranscript != nil
            ))
        }
        if let liveTranscript {
            blocks.append(liveTranscriptBlock(liveTranscript))
        }
        if let text = text?.nilIfBlank {
            blocks.append(text)
        }
        return blocks
    }

    private static func encodeContext(_ context: CodexChatContext) -> String {
        encodeContext(context, isLiveMode: false)
    }

    private static func encodeContext(
        _ context: CodexChatContext?,
        isLiveMode: Bool,
        containsLiveTranscript: Bool = false
    ) -> String {
        var lines = ["<context>"]
        if isLiveMode {
            lines.append(liveModeDescription)
        }
        if containsLiveTranscript {
            lines.append(hiddenLiveTranscriptDescription)
        }
        switch context {
        case let .meeting(id, name, calendarEvent):
            lines.append("  You are viewing a meeting in the Dahlia App.")
            lines.append("  Type: Meeting")
            lines.append(element(name: "meeting_id", value: id.uuidString, indentation: 2))
            lines.append(element(name: "meeting_name", value: name, indentation: 2))
            append(calendarEvent, to: &lines)
        case let .meetingDraft(_, name, calendarEvent):
            lines.append("  You are viewing an unsaved meeting draft in the Dahlia App.")
            lines.append("  Type: MeetingDraft")
            lines.append(element(name: "meeting_name", value: name, indentation: 2))
            append(calendarEvent, to: &lines)
        case nil:
            break
        }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }

    static func decode(_ prompt: String) -> (text: String, context: CodexChatContext?) {
        guard prompt.hasPrefix(contextStart),
              let contextEndRange = prompt.range(of: contextEnd),
              contextEndRange.lowerBound > prompt.startIndex
        else {
            return (prompt, nil)
        }

        let contextBlock = String(prompt[..<contextEndRange.lowerBound]) + "</context>"
        let text = String(prompt[contextEndRange.upperBound...])
        guard let context = canonicalContext(from: contextBlock) else {
            return (prompt, nil)
        }
        return (text, context)
    }

    static func decodeTextBlocks(_ textBlocks: [String]) -> (text: String, context: CodexChatContext?) {
        guard !textBlocks.isEmpty else { return ("", nil) }
        if let decoded = decodeLiveModeTextBlocks(textBlocks) {
            return decoded
        }
        let visibleBlocks = textBlocks.filter { !isDahliaLiveTranscriptBlock($0) }
        guard let firstVisibleBlock = visibleBlocks.first else { return ("", nil) }
        if visibleBlocks.count == 2,
           let context = canonicalContext(from: firstVisibleBlock) {
            return (visibleBlocks[1], context)
        }
        return decodeUserText(visibleBlocks.joined(separator: "\n"))
    }

    static func visibleUserText(from text: String) -> String {
        decodeTextBlocks([text]).text
    }

    private static func decodeLiveModeTextBlocks(
        _ textBlocks: [String]
    ) -> (text: String, context: CodexChatContext?)? {
        guard let first = textBlocks.first,
              first.hasPrefix("<context>\n" + liveModeDescription + "\n"),
              first.hasSuffix("\n</context>") else { return nil }

        var contextBlock = first.replacing(liveModeDescription + "\n", with: "")
        contextBlock = contextBlock.replacing(hiddenLiveTranscriptDescription + "\n", with: "")
        let context = contextBlock == "<context>\n</context>" ? nil : canonicalContext(from: contextBlock)
        guard context != nil || contextBlock == "<context>\n</context>" else { return nil }

        var visibleBlocks = Array(textBlocks.dropFirst())
        if first.contains("\n" + hiddenLiveTranscriptDescription + "\n"),
           let transcript = visibleBlocks.first,
           isCanonicalLiveTranscriptBlock(transcript) {
            visibleBlocks.removeFirst()
        }
        visibleBlocks.removeAll(where: isDahliaLiveTranscriptBlock)
        return (visibleBlocks.joined(separator: "\n"), context)
    }

    private static func liveTranscriptBlock(_ text: String) -> String {
        dahliaLiveTranscriptStart + escape(text) + liveTranscriptEnd
    }

    private static func isCanonicalLiveTranscriptBlock(_ block: String) -> Bool {
        isLiveTranscriptBlock(block, start: liveTranscriptStart)
    }

    private static func isDahliaLiveTranscriptBlock(_ block: String) -> Bool {
        isLiveTranscriptBlock(block, start: dahliaLiveTranscriptStart)
    }

    private static func isLiveTranscriptBlock(_ block: String, start: String) -> Bool {
        guard block.hasPrefix(start), block.hasSuffix(liveTranscriptEnd) else { return false }
        let valueStart = block.index(block.startIndex, offsetBy: start.count)
        let valueEnd = block.index(block.endIndex, offsetBy: -liveTranscriptEnd.count)
        let encoded = String(block[valueStart ..< valueEnd])
        guard let decoded = unescape(encoded) else { return false }
        return start + escape(decoded) + liveTranscriptEnd == block
    }

    private static func decodeUserText(_ text: String) -> (text: String, context: CodexChatContext?) {
        if let decoded = decodeLiveModePrefix(from: text) {
            return decoded
        }
        let decoded = decode(text)
        if decoded.context != nil {
            return decoded
        }
        return decodeContextPrefix(from: text) ?? decoded
    }

    private static func decodeLiveModePrefix(from text: String) -> (text: String, context: CodexChatContext?)? {
        guard text.hasPrefix("<context>\n" + liveModeDescription + "\n"),
              let closingRange = text.range(of: contextClosingTag)
        else { return nil }
        let contextBlock = String(text[..<closingRange.upperBound])
        guard let decodedContext = decodeLiveModeTextBlocks([contextBlock]) else { return nil }
        let remainder = String(text[closingRange.upperBound...])
        let visibleText = isCanonicalLiveTranscriptBlock(remainder) || isDahliaLiveTranscriptBlock(remainder)
            ? ""
            : remainder
        return (visibleText, decodedContext.context)
    }

    private static func decodeContextPrefix(from text: String) -> (text: String, context: CodexChatContext)? {
        guard text.hasPrefix(contextStart),
              let closingRange = text.range(of: contextClosingTag)
        else { return nil }
        let contextBlock = String(text[..<closingRange.upperBound])
        guard let context = canonicalContext(from: contextBlock) else { return nil }
        return (String(text[closingRange.upperBound...]), context)
    }

    private static func canonicalContext(from block: String) -> CodexChatContext? {
        guard let context = decodeContext(block), encodeContext(context) == block else { return nil }
        return context
    }

    private static func append(
        _ calendarEvent: CodexChatCalendarEventContext?,
        to lines: inout [String]
    ) {
        guard let calendarEvent else { return }
        lines.append("")
        lines.append("  <calendar_event>")
        if let icalUID = calendarEvent.icalUID?.nilIfBlank {
            lines.append(element(name: "ical_uid", value: icalUID, indentation: 4))
        }
        lines.append(element(name: "title", value: calendarEvent.title, indentation: 4))
        lines.append(element(name: "description", value: calendarEvent.description, indentation: 4))
        lines.append(element(name: "start", value: format(calendarEvent.start), indentation: 4))
        lines.append(element(name: "end", value: format(calendarEvent.end), indentation: 4))
        lines.append("  </calendar_event>")
    }

    private static func decodeContext(_ block: String) -> CodexChatContext? {
        var parser = CodexChatContextParser(block)
        guard parser.consume(contextStart) else { return nil }

        if parser.consume(meetingDescription) {
            guard parser.consume("  Type: Meeting\n"),
                  let idText = parser.consumeElement(name: "meeting_id", indentation: 2),
                  let id = UUID(uuidString: idText),
                  let name = parser.consumeElement(name: "meeting_name", indentation: 2)
            else { return nil }
            let calendarEvent = parser.consumeCalendarEvent()
            guard calendarEvent.isValid,
                  parser.consume("</context>"),
                  parser.isAtEnd else { return nil }
            return .meeting(id: id, name: name, calendarEvent: calendarEvent.context)
        }

        if parser.consume(meetingDraftDescription) {
            guard parser.consume("  Type: MeetingDraft\n"),
                  let name = parser.consumeElement(name: "meeting_name", indentation: 2)
            else { return nil }
            let calendarEvent = parser.consumeCalendarEvent()
            guard calendarEvent.isValid,
                  parser.consume("</context>"),
                  parser.isAtEnd else { return nil }
            return .meetingDraft(id: nil, name: name, calendarEvent: calendarEvent.context)
        }

        return nil
    }

    private static func element(name: String, value: String, indentation: Int) -> String {
        let spaces = String(repeating: " ", count: indentation)
        return "\(spaces)<\(name)>\(escape(value))</\(name)>"
    }

    static func unescape(_ value: String) -> String? {
        let decoded = value
            .replacing("&#13;", with: "\r")
            .replacing("&#10;", with: "\n")
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&quot;", with: "\"")
            .replacing("&apos;", with: "'")
            .replacing("&amp;", with: "&")
        return escape(decoded) == value ? decoded : nil
    }

    private static func escape(_ value: String) -> String {
        value
            .replacing("&", with: "&amp;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
            .replacing("'", with: "&apos;")
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
