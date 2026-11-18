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
