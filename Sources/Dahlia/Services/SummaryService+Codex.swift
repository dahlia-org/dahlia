import Foundation

extension SummaryService {
    struct CodexInputContext {
        let projectName: String?
        let projectDescription: String?
        let meetingId: UUID
        let createdAt: Date
        let transcriptText: String
        let noteText: String?
        let screenshots: [MeetingScreenshotRecord]
        let recordingSessions: [RecordingSessionTimeline]
    }

    static let codexStructuredInstruction = """

    # Response Format
    Your response MUST be a JSON object with exactly five keys:
    - "title": a concise title for this meeting/transcript (one line, no quotes, maximum 120 characters)
    - "description": a concise one-line description that helps identify the meeting (maximum 240 characters)
    - "sections": an array of summary body sections that exclude action items. Each section has:
      - "heading": the section heading, or an empty string for an intro section
      - "blocks": an array of content blocks in reading order
    - "tags": an array of relevant short Obsidian-compatible tags for categorization (empty array if none)
      - Tags MUST contain no spaces.
      - Tags MUST not be numeric-only.
      - Tags MUST use only letters, numbers, "_" and "-".
      - Use "_" or "-" to join words instead of spaces or punctuation.
      - Do not include "#", slashes, emojis, quotes, brackets, commas, or other symbols.
    - "action_items": the only location for action items; an array of objects with exactly two keys:
      - "title": the concrete action item
      - "assignee": who owns it, or an empty string if unclear

    Each block MUST be one object with all of these keys:
    - "type": one of "paragraph", "bulleted_list", "numbered_list", "checklist", "quote", "code", "image", "heading"
    - "level": heading level for "heading"; otherwise 0
    - "content": paragraph/quote/heading text, code body, or image caption; otherwise {"text":"","transcript_ref":null}
      - "content.text": the actual text
      - "content.transcript_ref": the most relevant HH:MM:SS timestamp for this text, or null
    - "items": list/checklist items; otherwise []
      - Each item has "text", "transcript_ref" as HH:MM:SS or null, and "checked" as true/false.
      - Use "checked": false for bulleted_list and numbered_list items.
    - "language": code language for "code"; otherwise empty string
    - "image_id": screenshot UUID for "image"; otherwise empty string

    Do not put transcript links inside text fields. Use content.transcript_ref or item.transcript_ref instead.
    Use inline Markdown only for emphasis and ordinary links inside text fields. Do not output tables; express them as lists.
    """

    static func makeCodexInputs(_ context: CodexInputContext) async -> [CodexAppServerInput] {
        var inputs: [CodexAppServerInput] = []
        if let projectContent = projectPromptContent(
            name: context.projectName,
            description: context.projectDescription
        ) {
            inputs.append(.text(projectContent))
        }

        var transcriptContent = "<meeting_id>\(context.meetingId.uuidString)</meeting_id>\n<transcript>\n\(context.transcriptText)\n</transcript>"
        if let noteText = context.noteText, !noteText.isEmpty {
            transcriptContent += "\n<note>\n\(noteText)\n</note>"
        }
        inputs.append(.text(transcriptContent))
        guard !context.screenshots.isEmpty else { return inputs }

        let imageDataURIs = await Task.detached(priority: .userInitiated) {
            context.screenshots.map { screenshot in
                let imageData = ImageEncoder.resized(screenshot.imageData, maxLongEdge: 1024)
                let mimeType = ImageEncoder.mimeType(for: imageData) ?? screenshot.mimeType
                return "data:\(mimeType);base64,\(imageData.base64EncodedString())"
            }
        }.value
        for (screenshot, imageDataURI) in zip(context.screenshots, imageDataURIs) {
            inputs.append(.imageMetadata(screenshotMetadata(
                for: screenshot,
                relativeTo: context.createdAt,
                recordingSessions: context.recordingSessions
            )))
            inputs.append(.imageDataURI(imageDataURI))
        }
        return inputs
    }
}
