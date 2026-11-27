import SwiftUI

struct AgentMCPServiceCard<Actions: View>: View {
    let name: String
    let comment: String
    let icon: Image
    @Binding var isEnabled: Bool
    /// Shown switched on and disabled: built in, with no way to turn it off.
    var isLocked = false
    /// The server's own name, shown when it differs from the service's.
    var alias: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                icon.resizable().scaledToFit().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(name).font(.dahliaHeadline)
                if let alias {
                    Text(alias).font(.dahliaSecondary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                actions.fixedSize()
                Toggle(name, isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.dahliaSwitch)
                    .controlSize(.small)
                    .accessibilityLabel(name)
                    .disabled(isLocked)
                    .fixedSize()
            }
            Text(comment)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                .strokeBorder(.separator.opacity(0.5))
        }
    }
}
