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
    let liveModeGeneration: UInt?

    init(
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot? = nil,
        liveModeGeneration: UInt? = nil
    ) {
        self.text = text
        self.images = images
        self.composerSnapshot = composerSnapshot
        self.liveModeGeneration = liveModeGeneration
    }
}
