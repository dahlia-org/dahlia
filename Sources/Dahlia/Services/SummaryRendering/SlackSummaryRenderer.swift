import Foundation

enum SlackSummaryRenderer {
    struct RenderedSection: Equatable {
        let sectionId: UUID
        let blocksJSON: String
    }

    struct RenderedMessage: Equatable {
        let sections: [RenderedSection]
    }

    static func render(document _: SummaryDocument, context _: SummaryRenderContext) -> RenderedMessage {
        // TODO: Convert each SummarySection into Slack Block Kit JSON.
        // Keep sectionId in RenderedSection so future updates can replace one section without reposting the whole summary.
        RenderedMessage(sections: [])
    }
}
