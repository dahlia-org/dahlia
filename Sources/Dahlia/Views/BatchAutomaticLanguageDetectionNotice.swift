import SwiftUI

struct BatchAutomaticLanguageDetectionNotice: View {
    let locales: [Locale]
    let displayLocale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.automaticDetectionMultilingualTitle)
                        .bold()
                    Text(L10n.automaticDetectionMultilingualDescription)
                }
            } icon: {
                Image(systemName: "character.bubble")
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.automaticDetectionLanguagesTitle)
                        .bold()
                    Text(languageNames)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "text.badge.checkmark")
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.automaticDetectionProcessingTimeTitle)
                        .bold()
                    Text(L10n.automaticDetectionProcessingTimeDescription)
                }
            } icon: {
                Image(systemName: "clock")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private var languageNames: String {
        let names = locales.map { locale in
            displayLocale.localizedString(forIdentifier: locale.identifier)
                ?? Locale.current.localizedString(forIdentifier: locale.identifier)
                ?? locale.identifier
        }
        guard !names.isEmpty else { return L10n.noAutomaticLanguageCandidates }
        return names.formatted(.list(type: .and).locale(displayLocale))
    }
}
