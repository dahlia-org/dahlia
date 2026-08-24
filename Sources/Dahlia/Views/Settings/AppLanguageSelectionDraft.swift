struct AppLanguageSelectionDraft {
    var scope: AppLanguageScope
    var enabledLanguageIdentifiers: Set<String>

    func commit(_ apply: (AppLanguageScope, Set<String>) -> Void) {
        apply(scope, enabledLanguageIdentifiers)
    }
}
