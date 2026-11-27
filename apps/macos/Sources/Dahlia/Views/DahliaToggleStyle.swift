import SwiftUI

/// The app's switch, drawn like Orca's: an accent-filled track when on, a gray track when off, and a round knob that
/// keeps the color that sits on the accent in both states.
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
                    : DahliaDesign.primaryButtonBackgroundColor(for: .normal).opacity(showsHover ? 0.66 : 0.6))
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(DahliaDesign.primaryButtonForegroundColor)
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

/// The app's checkbox: an accent-filled box with a check drawn in the color that sits on the accent, matching the switch.
/// The whole row, label included, toggles it like the native checkbox. Labels after the first read as the description.
struct DahliaCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DahliaCheckbox(configuration: configuration)
            .accessibilityRepresentation { Toggle(configuration) }
    }
}

private struct DahliaCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    var body: some View {
        let size: CGFloat = controlSize == .small || controlSize == .mini ? 14 : 16
        let state: DahliaDesign.Button.InteractionState = isEnabled && isHovered ? .hovered : .normal
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn
                        ? DahliaDesign.primaryButtonBackgroundColor(for: state)
                        : DahliaDesign.secondaryButtonBackgroundColor(for: state))
                    .overlay {
                        if configuration.isOn {
                            DahliaCheckmark()
                                .stroke(
                                    DahliaDesign.primaryButtonForegroundColor,
                                    style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                                )
                                .padding(size * 0.22)
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(isHovered && isEnabled ? 0.35 : 0.25), lineWidth: 1)
                        }
                    }
                    .frame(width: size, height: size)
                    // Centers the box on the first line of the label.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + size * 0.3 }
                VStack(alignment: .leading, spacing: 2) {
                    Group(subviews: configuration.label) { subviews in
                        ForEach(subviews.indices, id: \.self) { index in
                            if index == 0 {
                                subviews[index]
                            } else {
                                subviews[index]
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                        }
                    }
                }
            }
            .contentShape(.rect)
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(isEnabled ? .link : nil)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct DahliaCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        }
    }
}

extension ToggleStyle where Self == DahliaCheckboxToggleStyle {
    static var dahliaCheckbox: DahliaCheckboxToggleStyle { DahliaCheckboxToggleStyle() }
}
