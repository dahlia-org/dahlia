import SwiftUI

/// An agent's mascot on a rounded tile of its color. As Orca draws it, the picture fills the tile and the tile's corners
/// cut it: each mascot is drawn to run off its square's edges.
struct AgentAvatarView: View {
    let avatar: String
    let color: String
    let size: CGFloat

    static func cornerRadius(_ size: CGFloat) -> CGFloat { size / 4 }

    var body: some View {
        Color(hex: color)
            .overlay {
                if let image = AgentAvatar.image(avatar) { Image(nsImage: image).resizable().interpolation(.high) }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: Self.cornerRadius(size), style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Picks an agent's mascot and tile color: the mascot steps left and right, the swatches below.
struct AgentAvatarPicker: View {
    @Binding var avatar: String
    @Binding var color: String

    private var index: Int { AgentAvatar.mascots.firstIndex(of: AgentAvatar.mascotID(avatar)) ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                step(-1, label: L10n.agentAvatarPrevious, systemImage: "chevron.left")
                neighborButton(-1, label: L10n.agentAvatarPrevious)
                AgentAvatarView(avatar: avatar, color: color, size: 112)
                neighborButton(1, label: L10n.agentAvatarNext)
                step(1, label: L10n.agentAvatarNext, systemImage: "chevron.right")
            }
            HStack(spacing: 8) {
                ForEach(AgentAvatar.colors, id: \.self) { swatch in
                    Button { color = swatch } label: {
                        Circle()
                            .fill(Color(hex: swatch))
                            .overlay { Circle().strokeBorder(.separator) }
                            .padding(3)
                            .overlay { if swatch == color { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                            .frame(width: 28, height: 28)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch)
                    .accessibilityAddTraits(swatch == color ? .isSelected : [])
                }
            }
        }
        .padding(16)
    }

    private func neighbor(_ offset: Int) -> String {
        let count = AgentAvatar.mascots.count
        return AgentAvatar.mascots[((index + offset) % count + count) % count]
    }

    /// The faded mascot beside the chosen one; clicking it chooses it, as the arrow beside it does.
    private func neighborButton(_ offset: Int, label: String) -> some View {
        NeighborMascotButton(avatar: AgentAvatar.mascot(neighbor(offset)), color: color, label: label) {
            avatar = AgentAvatar.mascot(neighbor(offset))
        }
    }

    private func step(_ offset: Int, label: String, systemImage: String) -> some View {
        Button { avatar = AgentAvatar.mascot(neighbor(offset)) } label: {
            Image(systemName: systemImage)
                .dahliaFixedSymbol()
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.dahlia(.secondary))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A neighbor in the picker: faded, and less so while the pointer is over it, so it reads as clickable.
private struct NeighborMascotButton: View {
    let avatar: String
    let color: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            AgentAvatarView(avatar: avatar, color: color, size: 64)
                .opacity(isHovered ? 0.85 : 0.5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
