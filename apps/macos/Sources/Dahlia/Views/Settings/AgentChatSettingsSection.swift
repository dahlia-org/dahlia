import SwiftUI

struct AgentChatSettingsSection: View {
    @AppStorage(AppSettings.chatDeliveryModeUserDefaultsKey) private var deliveryMode: CodexChatDeliveryMode = .queue
    @AppStorage(AppSettings.chatContinueAfterRestartUserDefaultsKey) private var continuesAfterRestart = true

    var body: some View {
        Section {
            Picker(L10n.chatFollowUpBehavior, selection: $deliveryMode) {
                ForEach(CodexChatDeliveryMode.allCases, id: \.self) { mode in
                    Text(mode.title).font(.dahliaBody).tag(mode)
                }
            }
            Toggle(isOn: $continuesAfterRestart) {
                Text(L10n.chatContinueAfterRestart)
                Text(L10n.chatContinueAfterRestartHelp)
            }
            .toggleStyle(.dahliaSwitch)
        } header: {
            Text(L10n.chat).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.chatFollowUpHelp)
        }
    }
}
