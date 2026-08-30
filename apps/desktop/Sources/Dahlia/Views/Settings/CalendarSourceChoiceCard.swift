import AppKit
import SwiftUI

struct CalendarSourceChoiceCard: View {
    let source: CalendarSource
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                sourceImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(source.displayName)
                        .font(.title3)
                        .bold()

                    Text(description)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .dahliaFixedSymbol()
            }
            .padding(14)
            .frame(minWidth: 280, maxWidth: 320, minHeight: 96, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? L10n.selected : "")
    }

    private var sourceImage: Image {
        guard source == .google,
              let url = Bundle.appModule.url(forResource: "GoogleCalendar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "calendar")
        }

        image.isTemplate = false
        return Image(nsImage: image)
    }

    private var description: String {
        switch source {
        case .google: L10n.googleCalendarSourceDescription
        case .macOS: L10n.macOSCalendarSourceDescription
        }
    }
}
