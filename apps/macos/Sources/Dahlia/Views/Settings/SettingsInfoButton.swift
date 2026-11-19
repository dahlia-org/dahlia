import SwiftUI

/// An info mark beside a settings label; hovering shows the help, and a click or VoiceOver opens it as a popover.
struct SettingsInfoButton: View {
    let help: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .dahliaFixedSymbol()
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $isPresented) {
            Text(help)
                .font(.dahliaBody)
                .padding(12)
                .frame(idealWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A settings switch whose explanation sits behind an info button instead of a paragraph below it.
struct SettingsInfoToggle: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn).labelsHidden()
        } label: {
            HStack {
                Text(title)
                SettingsInfoButton(help: help)
            }
        }
    }
}
