import SwiftUI

/// The npm registry Dahlia-managed Pi installs and updates from, kept for the account; installs read it when they start.
struct PiRegistryField: View {
    @AppStorage(PiInstaller.registryDefaultsKey()) private var registry = ""

    var body: some View {
        LabeledContent {
            TextField(L10n.piRegistry, text: $registry, prompt: Text(L10n.piRegistryDefault))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        } label: {
            Text(L10n.piRegistry)
        }
    }
}

/// Opened from the Pi install and update buttons. The field saves as it changes; the next install or update reads it.
struct PiRegistryModal: View {
    let onClose: () -> Void

    var body: some View {
        AgentPluginSettingsModal(height: 240, onClose: onClose) {
            Form {
                Section {
                    PiRegistryField()
                } header: {
                    Text(L10n.piRegistrySettings).font(.dahliaSectionHeader)
                } footer: {
                    Text(L10n.piRegistryHelp).font(.dahliaSecondary).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button(L10n.close, action: onClose)
                .buttonStyle(.dahlia())
                .keyboardShortcut(.cancelAction)
        }
    }
}
