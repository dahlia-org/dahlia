import SwiftUI

struct AppLanguageSelectionRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isSelectionPresented = false

    var body: some View {
        LabeledContent(L10n.languageRange) {
            Button(selectionSummary) {
                isSelectionPresented = true
            }
        }
        .sheet(isPresented: $isSelectionPresented) {
            AppLanguageSelectionSheet(
                scope: settings.appLanguageScope,
                enabledLanguageIdentifiers: settings.enabledLanguageIdentifiers
            ) { scope, identifiers in
                settings.enabledLanguageIdentifiers = identifiers
                settings.appLanguageScope = scope
            }
        }
    }

    private var selectionSummary: String {
        Self.selectionSummary(
            scope: settings.appLanguageScope,
            identifiers: settings.enabledLanguageIdentifiers
        )
    }

    static func selectionSummary(
        scope: AppLanguageScope,
        identifiers: Set<String>,
        locale: Locale = .current
    ) -> String {
        guard scope == .selected else { return L10n.allSupportedLanguages }
        let summary = summaryParts(identifiers: identifiers, locale: locale)
        let names = summary.names.joined(separator: ", ")
        guard !names.isEmpty else { return L10n.languagesSelected(0) }
        guard summary.remainingCount > 0 else { return names }
        return "\(names), \(L10n.additionalLanguages(summary.remainingCount))"
    }

    static func summaryParts(
        identifiers: Set<String>,
        locale: Locale = .current
    ) -> (names: [String], remainingCount: Int) {
        let names = identifiers
            .map { AppLanguageSelection(id: $0).displayName(locale: locale) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let displayedNames = Array(names.prefix(2))
        return (displayedNames, names.count - displayedNames.count)
    }
}
