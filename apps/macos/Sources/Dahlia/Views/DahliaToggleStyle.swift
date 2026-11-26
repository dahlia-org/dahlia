import SwiftUI

/// The app's switch, drawn like Orca's: an accent-filled track with a round knob in the color that sits on the accent.
/// The native switch cannot recolor its knob, so the near-white dark-mode accent would hide a white knob.
struct DahliaSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // LabeledContent keeps the native label placement in grouped forms and honors `.labelsHidden()`.
        LabeledContent {
            DahliaSwitch(isOn: configuration.$isOn)
                .accessibilityRepresentation { Toggle(configuration) }
        } label: {
            configuration.label
        }
    }
}

private struct DahliaSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let height: CGFloat = controlSize == .small || controlSize == .mini ? 16 : 22
        let inset: CGFloat = 3
        let width = height * 1.75
        let showsHover = isEnabled && isHovered
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn
                    ? DahliaDesign.primaryButtonBackgroundColor(for: showsHover ? .hovered : .normal)
                    : Color.primary.opacity(showsHover ? 0.24 : 0.18))
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(isOn ? DahliaDesign.primaryButtonForegroundColor : Color.primary)
                        .padding(inset)
                        .offset(x: isOn ? width - height : 0)
                }
                .contentShape(.capsule)
                // Implicit, so the knob also slides when the bound setting is written back asynchronously.
                .animation(.snappy(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : nil)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ToggleStyle where Self == DahliaSwitchToggleStyle {
    static var dahliaSwitch: DahliaSwitchToggleStyle { DahliaSwitchToggleStyle() }
}
