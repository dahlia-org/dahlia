import SwiftUI

struct CodexChatLiveModeStartButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var helpController = DahliaWindowHeaderHelpController()
    @State private var helpID = UUID()
    @State private var helpSize: CGSize = .zero
    @State private var buttonFrame: CGRect = .zero

    var body: some View {
        Button(action: action) {
            Label(L10n.enableChatLiveMode, systemImage: "waveform.badge.microphone")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.61, green: 0.50, blue: 0.93),
                    Color(red: 0.45, green: 0.34, blue: 0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Circle()
        )
        .overlay {
            if helpController.visibleHelpID == helpID {
                DahliaWindowHeaderHelp(label: L10n.chatLiveMode, shortcut: nil)
                    .onGeometryChange(for: CGSize.self) { geometry in
                        geometry.size
                    } action: { size in
                        helpSize = size
                    }
                    .offset(x: helpHorizontalOffset, y: helpVerticalOffset)
                    .opacity(helpSize == .zero ? 0 : 1)
            }
        }
        .shadow(color: .purple.opacity(isEnabled ? 0.24 : 0), radius: 4, y: 1)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            buttonFrame = frame
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName))
                ?? geometry.frame(in: .local)
        } action: { bounds in
            helpController.updateWindowBounds(bounds)
        }
        .onHover(perform: updateHelpHover)
        .onDisappear { helpController.hoverEnded(for: helpID) }
        .zIndex(helpController.visibleHelpID == helpID ? 1 : 0)
    }

    private func updateHelpHover(_ isHovering: Bool) {
        if isHovering {
            helpController.hoverBegan(for: helpID)
        } else {
            helpController.hoverEnded(for: helpID)
        }
    }

    private var helpHorizontalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: buttonFrame.width / 2,
            helpWidth: helpSize.width,
            windowBounds: helpController.windowBounds
        )
    }

    private var helpVerticalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.verticalOffset(
            buttonMinY: buttonFrame.minY,
            helpHeight: helpSize.height,
            buttonHeight: buttonFrame.height
        )
    }
}
