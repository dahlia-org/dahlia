import Foundation

struct CodexChatComposerSnapshot: Equatable, Sendable {
    let draft: String
    let referenceIDs: [UUID]
    let images: [CodexChatImageAttachment]
    var threadReferences: [CodexChatThreadSummary] = []

    var threadReferenceIDs: [String] { threadReferences.map(\.id) }
}

struct CodexChatManualSubmission: Identifiable, Equatable, Sendable {
    let id: UUID
    var clearsComposerOnDelivery = true
    var deliveryMode: CodexChatDeliveryMode
    var startsFreshSession: Bool
    let text: String
    let images: [CodexChatImageAttachment]
    let composerSnapshot: CodexChatComposerSnapshot?
    let includesCurrentContext: Bool

    init(
        id: UUID = .v7(),
        deliveryMode: CodexChatDeliveryMode = .steer,
        startsFreshSession: Bool = false,
        text: String,
        images: [CodexChatImageAttachment],
        composerSnapshot: CodexChatComposerSnapshot? = nil,
        includesCurrentContext: Bool = true
    ) {
        self.id = id
        self.deliveryMode = deliveryMode
        self.startsFreshSession = startsFreshSession
        self.text = text
        self.images = images
        self.composerSnapshot = composerSnapshot
        self.includesCurrentContext = includesCurrentContext
    }
}
