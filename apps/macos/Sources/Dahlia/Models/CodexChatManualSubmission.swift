import Foundation

struct CodexChatComposerSnapshot: Equatable, Sendable {
    let draft: String
    let referenceIDs: [UUID]
    let images: [CodexChatImageAttachment]
    var threadReferenceIDs: [String] = []
}

struct CodexChatManualSubmission: Identifiable, Equatable, Sendable {
    let id: UUID
    var clearsComposerOnDelivery = true
    var deliveryMode: CodexChatDeliveryMode
    let text: String
    let images: [CodexChatImageAttachment]
    let composerSnapshot: CodexChatComposerSnapshot?
    let includesCurrentContext: Bool

    init(
        id: UUID = .v7(),
        deliveryMode: CodexChatDeliveryMode = .steer,
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot? = nil,
        includesCurrentContext: Bool = true
    ) {
        self.id = id
        self.deliveryMode = deliveryMode
        self.text = text
        self.images = images
        self.composerSnapshot = composerSnapshot
        self.includesCurrentContext = includesCurrentContext
    }
}
