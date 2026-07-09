import Foundation

enum GoogleDocsSummaryRenderer {
    struct SectionBatchUpdate: Equatable {
        let sectionId: UUID
        let requestsJSON: String
        let inlineImageScreenshotIds: [UUID]
    }

    struct RenderedDocument: Equatable {
        let sections: [SectionBatchUpdate]
    }

    static func render(document _: SummaryDocument, context _: SummaryRenderContext) -> RenderedDocument {
        // TODO: Convert SummarySection values into Google Docs batchUpdate requests.
        // inlineImageScreenshotIds is the handoff point for uploading screenshots and binding them to section updates.
        RenderedDocument(sections: [])
    }
}
