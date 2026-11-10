import AppKit
import SwiftUI

/// A large card button for setup. In the `.choice` style it picks one option among several, which a circle marks and
/// a highlight shows. In the `.action` style it starts an action, such as a sign-in, and a check mark shows once the
/// action is done. Place cards in an `HStack` with `.fixedSize(horizontal: false, vertical: true)` so that cards in a
/// row share one height.
struct SetupChoiceCard: View {
    enum Style {
        case choice
        case action
    }

    let image: Image
    let title: String
    let description: String
    let isSelected: Bool
    var style = Style.choice
    var isBusy = false
    var selectedAccessibilityValue = L10n.selected
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    // A title may break its own line; a line too long for two lines shrinks instead of truncating.
                    Text(title)
                        .font(.title3)
                        .bold()
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(description)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                stateIndicator
            }
            .padding(14)
            .frame(minWidth: 280, maxWidth: 320, minHeight: 96, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .background(background, in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                    .stroke(
                        isHighlighted ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isHighlighted ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(isSelected ? selectedAccessibilityValue : "")
    }

    private var isHighlighted: Bool {
        style == .choice && isSelected
    }

    private var background: Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.12)
        }
        return isHovered ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            switch style {
            case .choice:
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .dahliaFixedSymbol()
            case .action:
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .dahliaFixedSymbol()
                }
            }
        }
    }
}

extension CalendarSource {
    var choiceCardImage: Image {
        guard self == .google,
              let url = Bundle.appModule.url(forResource: "GoogleCalendar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "calendar")
        }

        image.isTemplate = false
        return Image(nsImage: image)
    }

    var choiceCardDescription: String {
        switch self {
        case .google: L10n.googleCalendarSourceDescription
        case .macOS: L10n.macOSCalendarSourceDescription
        }
    }
}
