struct AppLanguageSelectionDraft {
    var scope: AppLanguageScope
    var enabledLanguageIdentifiers: Set<String>

    var isValid: Bool {
        scope == .all || !enabledLanguageIdentifiers.isEmpty
    }

    func commit(_ apply: (AppLanguageScope, Set<String>) -> Void) {
        guard isValid else { return }
        apply(scope, enabledLanguageIdentifiers)
    }
}
