import SwiftUI

struct AgentChatInstructionsSection: View {
    @AppStorage private var instructions: String
    @State private var isInfoPresented = false

    init(account: CodexRuntimeProvider) {
        _instructions = AppStorage(wrappedValue: "", AgentChatInstructions.defaultsKey(for: account))
    }

    var body: some View {
        Section {
            TextField(L10n.chatCustomInstructions, text: $instructions, axis: .vertical)
                .lineLimit(5...)
        } header: {
            HStack {
                Text(L10n.chatCustomInstructions).font(.dahliaSectionHeader)
                Button { isInfoPresented = true } label: {
                    Image(systemName: "info.circle")
                        .dahliaFixedSymbol()
                        .imageScale(.small)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .padding(2)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isInfoPresented = $0 }
                .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                    Text(L10n.chatCustomInstructionsInfo)
                        .font(.dahliaBody)
                        .padding(12)
                        .frame(idealWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityLabel(L10n.chatCustomInstructionsDetails)
            }
        } footer: {
            Text(L10n.chatCustomInstructionsHelp)
        }
    }
}
