import SwiftUI

struct AgentMCPServiceCard<Actions: View>: View {
    let name: String
    let comment: String
    let icon: Image
    @Binding var isEnabled: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                icon.resizable().scaledToFit().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(name).font(.dahliaHeadline)
                Spacer(minLength: 0)
                actions.fixedSize()
                Toggle(name, isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(name)
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
