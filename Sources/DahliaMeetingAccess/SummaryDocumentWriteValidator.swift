import DahliaRuntimeSupport
import Foundation

enum SummaryDocumentWriteValidator {
    static func validate(_ document: SummaryDocument) throws {
        guard SummaryDocumentSchemaVersion.acceptedMCPWriteVersions.contains(document.schemaVersion) else {
            throw MeetingAccessError.invalidSummaryUpdate("schema_version must be 3 or 4.")
        }
        guard StoredSummaryDocumentMarkdownRenderer.hasValidTranscriptReferences(document) else {
            throw MeetingAccessError.invalidSummaryUpdate("transcript_ref must match HH:MM:SS.")
        }

        for block in document.sections.flatMap(\.blocks) {
            let items: [(text: SummaryText, indent: Int)] = switch block.content {
            case let .bulletedList(items), let .numberedList(items):
                items.map { (text: $0.text, indent: $0.indent) }
            case let .checklist(items):
                items.map { (text: $0.text, indent: $0.indent) }
            default:
                []
            }
            try validate(items, schemaVersion: document.schemaVersion)
        }
    }

    private static func validate(
        _ items: [(text: SummaryText, indent: Int)],
        schemaVersion: Int
    ) throws {
        guard items.allSatisfy({ (0 ... 2).contains($0.indent) }) else {
            throw MeetingAccessError.invalidSummaryUpdate("List item indent must be 0, 1, or 2.")
        }
        if schemaVersion == 3, items.contains(where: { $0.indent != 0 }) {
            throw MeetingAccessError.invalidSummaryUpdate("schema_version 3 does not support non-zero list item indent.")
        }
        if schemaVersion == 4, items.contains(where: { $0.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw MeetingAccessError.invalidSummaryUpdate("schema_version 4 list items must not be blank.")
        }
        guard let first = items.first else { return }
        guard first.indent == 0 else {
            throw MeetingAccessError.invalidSummaryUpdate("The first list item must have indent 0.")
        }
        for (previous, current) in zip(items, items.dropFirst()) where current.indent > previous.indent + 1 {
            throw MeetingAccessError.invalidSummaryUpdate("List item indent must not skip a hierarchy level.")
        }
    }
}
