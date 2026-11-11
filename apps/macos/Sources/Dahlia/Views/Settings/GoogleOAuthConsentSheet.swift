import SwiftUI

enum GoogleOAuthDisclosure: String, Identifiable {
    case calendar

    nonisolated static let privacyPolicyURL = URL(string: "https://dahlia-ai.org/privacy/")!
    nonisolated static let japanesePrivacyPolicyURL = URL(string: "https://dahlia-ai.org/ja/privacy/")!

    nonisolated static func privacyPolicyURL(for locale: Locale) -> URL {
        locale.language.languageCode?.identifier == "ja" ? japanesePrivacyPolicyURL : privacyPolicyURL
    }

    var id: String { rawValue }

    var title: String { L10n.googleCalendarOAuthDisclosureTitle }

    var overview: String { L10n.googleCalendarOAuthDisclosureOverview }

    var accessedData: String { L10n.googleCalendarOAuthDisclosureAccess }

    var useAndStorage: String { L10n.googleCalendarOAuthDisclosureUseAndStorage }

    var externalSharing: String { L10n.googleCalendarOAuthDisclosureExternalSharing }

    var deletion: String { L10n.googleCalendarOAuthDisclosureDeletion }
}

struct GoogleOAuthConsentState {
    var pendingDisclosure: GoogleOAuthDisclosure?
    private var isConsentGranted = false

    mutating func request(_ disclosure: GoogleOAuthDisclosure) {
        pendingDisclosure = disclosure
        isConsentGranted = false
    }

    mutating func grantConsent() {
        isConsentGranted = true
    }

    mutating func consumeConsent() -> Bool {
        defer { isConsentGranted = false }
        return isConsentGranted
    }
}

struct GoogleOAuthConsentSheet: View {
    let disclosure: GoogleOAuthDisclosure
    let onConsent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: disclosure.title)

            Form {
                Section {
                    Text(disclosure.overview)
                }

                Section {
                    Text(disclosure.accessedData)
                } header: {
                    Text(L10n.googleOAuthDisclosureDataAccess)
                        .font(.dahliaSectionHeader)
                }

                Section {
                    Text(disclosure.useAndStorage)
                } header: {
                    Text(L10n.googleOAuthDisclosureUseAndStorage)
                        .font(.dahliaSectionHeader)
                }

                Section {
                    Text(disclosure.externalSharing)
                } header: {
                    Text(L10n.googleOAuthDisclosureExternalSharing)
                        .font(.dahliaSectionHeader)
                }

                Section {
                    Text(disclosure.deletion)
                    Link(
                        L10n.viewPrivacyPolicy,
                        destination: GoogleOAuthDisclosure.privacyPolicyURL(for: settings.appLanguage.locale)
                    )
                } header: {
                    Text(L10n.googleOAuthDisclosureManageAndDelete)
                        .font(.dahliaSectionHeader)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)

            DahliaSheetActionBar {
                Button(L10n.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.continueToGoogle) {
                    onConsent()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dahliaSimpleWindowStyle()
    }
}
