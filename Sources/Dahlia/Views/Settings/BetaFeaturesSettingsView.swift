import SwiftUI

struct BetaFeaturesSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    L10n.customerIntelligence,
                    isOn: $settings.isCustomerIntelligenceBetaEnabled
                )
                .toggleStyle(.switch)
            } header: {
                Text(L10n.betaFeatures)
            } footer: {
                Text(L10n.betaFeaturesDescription)
            }
        }
        .formStyle(.grouped)
    }
}
