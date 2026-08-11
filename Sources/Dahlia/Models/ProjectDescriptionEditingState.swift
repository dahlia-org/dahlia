struct ProjectDescriptionEditingState: Equatable {
    let text: String
    let persistedText: String
    let expectedRevision: Int?

    init(
        persistedText: String?,
        draftText: String?,
        persistedRevision: Int? = nil,
        draftRevision: Int? = nil
    ) {
        let persistedText = persistedText ?? ""
        self.text = draftText ?? persistedText
        self.persistedText = persistedText
        expectedRevision = draftText == nil ? persistedRevision : draftRevision ?? persistedRevision
    }
}
