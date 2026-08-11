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

    var title: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureTitle
        case .drive:
            L10n.googleDriveOAuthDisclosureTitle
        }
    }

    var overview: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureOverview
        case .drive:
            L10n.googleDriveOAuthDisclosureOverview
        }
    }

    var accessedData: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureAccess
        case .drive:
            L10n.googleDriveOAuthDisclosureAccess
        }
    }

    var useAndStorage: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureUseAndStorage
        case .drive:
            L10n.googleDriveOAuthDisclosureUseAndStorage
        }
    }

    var externalSharing: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureExternalSharing
        case .drive:
            L10n.googleDriveOAuthDisclosureExternalSharing
        }
    }

    var deletion: String {
        switch self {
        case .calendar:
            L10n.googleCalendarOAuthDisclosureDeletion
        case .drive:
            L10n.googleDriveOAuthDisclosureDeletion
        }
    }
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
        NavigationStack {
            Form {
                Section {
                    Text(disclosure.overview)
                }

                Section {
                    Text(disclosure.accessedData)
                } header: {
                    Text(L10n.googleOAuthDisclosureDataAccess)
                }

                Section {
                    Text(disclosure.useAndStorage)
                } header: {
                    Text(L10n.googleOAuthDisclosureUseAndStorage)
                }

                Section {
                    Text(disclosure.externalSharing)
                } header: {
                    Text(L10n.googleOAuthDisclosureExternalSharing)
                }

                Section {
                    Text(disclosure.deletion)
                    Link(
                        L10n.viewPrivacyPolicy,
                        destination: GoogleOAuthDisclosure.privacyPolicyURL(for: settings.appLanguage.locale)
                    )
                } header: {
                    Text(L10n.googleOAuthDisclosureManageAndDelete)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(disclosure.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.continueToGoogle) {
                        onConsent()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
