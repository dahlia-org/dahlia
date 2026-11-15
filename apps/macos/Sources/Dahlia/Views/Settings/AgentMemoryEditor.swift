import SwiftUI

struct AgentMemoryEditor: View {
    let model: AgentLearningSettingsModel
    let target: String
    @State var content: String
    let onClose: () -> Void
    let onSave: (String) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        let title = target == "user" ? L10n.agentMemoryUser : L10n.agentMemoryEnvironment
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
            .disabled(model.isBusy)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.dahliaTitle2)
                        .accessibilityAddTraits(.isHeader)
                    Text(target == "user" ? L10n.agentMemoryUserExample : L10n.agentMemoryEnvironmentExample)
                        .font(.dahliaSecondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: $content)
                    .scrollContentBackground(.hidden)
                    .frame(height: 180)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .focused($isFocused)
                    .accessibilityLabel(title)
                    .disabled(model.isBusy)
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button(L10n.cancel, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isBusy)
                    Button(L10n.save) { onSave(content) }
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 540)
            .dahliaModalSurface()
            .padding(24)
        }
        .font(.dahliaBody)
        .onAppear { isFocused = true }
    }
}
