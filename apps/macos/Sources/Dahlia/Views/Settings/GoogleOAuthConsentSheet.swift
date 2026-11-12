import SwiftUI

enum GoogleOAuthDisclosure: String, Identifiable {
    case calendar
    case drive

    nonisolated static let privacyPolicyURL = URL(string: "https://dahlia-ai.org/privacy/")!
    nonisolated static let japanesePrivacyPolicyURL = URL(string: "https://dahlia-ai.org/ja/privacy/")!

    nonisolated static func privacyPolicyURL(for locale: Locale) -> URL {
        locale.language.languageCode?.identifier == "ja" ? japanesePrivacyPolicyURL : privacyPolicyURL
    }

    var id: String { rawValue }

    var title: String { self == .drive ? L10n.googleDriveOAuthDisclosureTitle : L10n.googleCalendarOAuthDisclosureTitle }

    var overview: String { self == .drive ? L10n.googleDriveOAuthDisclosureOverview : L10n.googleCalendarOAuthDisclosureOverview }

    var accessedData: String { self == .drive ? L10n.googleDriveOAuthDisclosureAccess : L10n.googleCalendarOAuthDisclosureAccess }

    var useAndStorage: String { self == .drive ? L10n.googleDriveOAuthDisclosureUseAndStorage : L10n.googleCalendarOAuthDisclosureUseAndStorage }

    var externalSharing: String { self == .drive ? L10n.googleDriveOAuthDisclosureExternalSharing : L10n.googleCalendarOAuthDisclosureExternalSharing
    }

    var deletion: String { self == .drive ? L10n.googleDriveOAuthDisclosureDeletion : L10n.googleCalendarOAuthDisclosureDeletion }
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
    var onClose: (() -> Void)?
    let onConsent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

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
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.continueToGoogle) {
                    onConsent()
                    close()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dahliaSimpleWindowStyle()
    }
}
