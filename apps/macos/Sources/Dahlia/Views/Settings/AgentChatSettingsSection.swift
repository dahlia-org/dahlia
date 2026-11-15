import SwiftUI

struct AgentChatSettingsSection: View {
    @AppStorage(AppSettings.chatDeliveryModeUserDefaultsKey) private var deliveryMode: CodexChatDeliveryMode = .queue

    var body: some View {
        Section {
            Picker(L10n.chatFollowUpBehavior, selection: $deliveryMode) {
                ForEach(CodexChatDeliveryMode.allCases, id: \.self) { mode in
                    Text(mode.title).font(.dahliaBody).tag(mode)
                }
            }
        } header: {
            Text(L10n.chat).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.chatFollowUpHelp)
        }
    }
}
