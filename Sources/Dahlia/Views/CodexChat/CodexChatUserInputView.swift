import SwiftUI

struct CodexChatUserInputView: View {
    let request: CodexChatUserInputRequest
    let isEnabled: Bool
    let onSubmit: (String) -> Void
    let onStop: () -> Void

    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.header)
                        .font(.body.weight(.semibold))
                    Text(request.question)
                        .font(.body)

                    ForEach(request.options) { option in
                        Button {
                            onSubmit(option.label)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                    .font(.body.weight(.medium))
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.dahlia())
                        .disabled(!isEnabled)
                    }

                    if request.allowsOther {
                        HStack {
                            TextField(L10n.chatUserInputOther, text: $other)
                            Button(L10n.chatUserInputSubmit) {
                                onSubmit(other)
                            }
                            .buttonStyle(.dahlia(.primary))
                            .disabled(!isEnabled || other.nilIfBlank == nil)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)

            Button(L10n.stopGenerating, systemImage: "stop.fill", action: onStop)
                .buttonStyle(.dahlia(.destructive))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: .rect(cornerRadius: CodexChatDesign.composerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}
