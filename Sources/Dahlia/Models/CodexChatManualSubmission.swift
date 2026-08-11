import Foundation

struct CodexChatComposerSnapshot: Equatable, Sendable {
    let draft: String
    let referenceIDs: [UUID]
    let images: [CodexChatImageAttachment]
}

struct CodexChatManualSubmission: Equatable, Sendable {
    let text: String
    let images: [CodexChatImageAttachment]
    let composerSnapshot: CodexChatComposerSnapshot?

    init(
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot? = nil
    ) {
        self.text = text
        self.images = images
        self.composerSnapshot = composerSnapshot
    }
}
