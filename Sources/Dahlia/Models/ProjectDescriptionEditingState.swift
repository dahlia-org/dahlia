struct ProjectDescriptionEditingState: Equatable {
    let text: String
    let persistedText: String

    var hasUnsavedChanges: Bool {
        text != persistedText
    }

    init(persistedText: String?, draftText: String?) {
        let persistedText = persistedText ?? ""
        self.text = draftText ?? persistedText
        self.persistedText = persistedText
    }
}
