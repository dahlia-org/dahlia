import AppKit
import SwiftUI

struct ModelProviderChoiceCard: View {
    let provider: AIAccountProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                providerImage
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.displayName)
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

    private var providerLogo: String {
        switch provider {
        case .chatGPTSubscription: "ProviderOpenAI"
        case .databricks: "ProviderDatabricks"
        }
    }

    private var providerImage: Image {
        guard let url = Bundle.appModule.url(forResource: providerLogo, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return Image(systemName: "sparkles")
        }
        image.isTemplate = provider == .chatGPTSubscription
        return Image(nsImage: image)
    }

    private var description: String {
        switch provider {
        case .chatGPTSubscription: L10n.chatGPTProviderDescription
        case .databricks: L10n.databricksProviderDescription
        }
    }
}
