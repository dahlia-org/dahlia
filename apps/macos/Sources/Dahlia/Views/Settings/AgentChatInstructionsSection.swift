import SwiftUI

struct AgentChatInstructionsSection: View {
    @AppStorage private var instructions: String

    init(account: CodexRuntimeProvider) {
        _instructions = AppStorage(wrappedValue: "", AgentChatInstructions.defaultsKey(for: account))
    }

    var body: some View {
        Section {
            TextField(L10n.chatCustomInstructions, text: $instructions, axis: .vertical)
                .lineLimit(5...)
        } header: {
            Text(L10n.chatCustomInstructions).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.chatCustomInstructionsHelp)
        }
    }
}
