import DahliaRuntimeSupport
import Foundation

enum SummaryDocumentWriteValidator {
    static func writeValidationError(_ document: SummaryDocument) -> String? {
        let acceptedVersions = SummaryDocumentSchemaVersion.acceptedMCPWriteVersions
        guard acceptedVersions.contains(document.schemaVersion) else {
            let versions = acceptedVersions.sorted().map(String.init).joined(separator: ", ")
            return "schema_version must be one of \(versions)."
        }

        let isCurrentVersion = document.schemaVersion == SummaryDocumentSchemaVersion.current
        for block in document.sections.flatMap(\.blocks) {
            let items: [(text: SummaryText, indent: Int)]
            switch block.content {
            case let .bulletedList(listItems), let .numberedList(listItems):
                items = listItems.map { ($0.text, $0.indent) }
            case let .checklist(checklistItems):
                items = checklistItems.map { ($0.text, $0.indent) }
            default:
                continue
            }

            guard items.allSatisfy({ 0 ... 2 ~= $0.indent }) else {
                return "List item indent must be 0, 1, or 2."
            }
            guard isCurrentVersion || items.allSatisfy({ $0.indent == 0 }) else {
                return "Only schema_version \(SummaryDocumentSchemaVersion.current) may contain nested list items."
            }
            if isCurrentVersion, items.contains(where: { $0.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "List item text must not be blank in schema_version \(SummaryDocumentSchemaVersion.current)."
            }
            if let first = items.first, first.indent != 0 {
                return "The first item in each list must have indent 0."
            }
            for (previous, item) in zip(items, items.dropFirst()) where item.indent > previous.indent + 1 {
                return "List item indent may increase by at most one level."
            }
        }

        guard hasValidTranscriptReferences(document) else {
            return "transcript_ref must match HH:MM:SS."
        }
        return nil
    }

    static func hasValidTranscriptReferences(_ document: SummaryDocument) -> Bool {
        document.sections
            .flatMap(\.blocks)
            .flatMap(transcriptReferenceTimes)
            .allSatisfy { $0.wholeMatch(of: /^[0-9]{2,}:[0-9]{2}:[0-9]{2}$/) != nil }
    }

    private static func transcriptReferenceTimes(_ block: SummaryBlock) -> [String] {
        let texts: [SummaryText] = switch block.content {
        case let .paragraph(text), let .quote(text):
            [text]
        case let .bulletedList(items), let .numberedList(items):
            items.map(\.text)
        case let .checklist(items):
            items.map(\.text)
        case let .code(_, text), let .image(_, text), let .heading(_, text):
            [text]
        case let .table(headers, rows):
            headers + rows.joined()
        }
        return texts.compactMap { $0.transcriptRef?.time }
    }
}
