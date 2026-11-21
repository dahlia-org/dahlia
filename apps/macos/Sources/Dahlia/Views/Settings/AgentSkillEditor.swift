import DahliaRuntimeSupport
import SwiftUI

/// Edits an account skill's SKILL.md. Saving goes through `skill_manage`, so the change lands in the skill's history
/// and can be undone there.
struct AgentSkillEditor: View {
    let account: CodexRuntimeProvider
    let name: String
    let onClose: () -> Void
    let onSaved: () -> Void
    @State private var content: String?
    @State private var original: AgentSkillSnapshot?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)
            .disabled(isSaving)

            VStack(alignment: .leading, spacing: 16) {
                Text(name)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)
                if let binding = Binding($content) {
                    TextEditor(text: binding)
                        .font(.dahliaBody.monospaced())
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 320)
                        .padding(8)
                        .background(.background, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.separator, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel(name)
                        .disabled(isSaving)
                } else if errorMessage == nil {
                    ProgressView().controlSize(.small)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button(L10n.cancel, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Button(L10n.save) { Task { await save() } }
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, maxHeight: 640)
            .dahliaModalSurface()
            .padding(24)
        }
        .font(.dahliaBody)
        .task {
            do {
                let service = try await PiChatService.shared.skillService()
                let root = try await PiChatService.shared.skillsRoot(account)
                let snapshot = try await service.editableSnapshot(name: name, account: account.accountKey, root: root)
                guard let data = snapshot.files["SKILL.md"], let text = String(data: data, encoding: .utf8)
                else { throw HermesLearning.failure("Skill is not UTF-8 text.") }
                original = snapshot
                content = text
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        guard let content, let original else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let service = try await PiChatService.shared.skillService()
            let root = try await PiChatService.shared.skillsRoot(account)
            let operation: JSONValue = .object(["action": .string("patch"), "name": .string(name), "content": .string(content)])
            _ = try await service.manageAccountSkills(
                payload: .object(["operations": .array([operation])]), account: account.accountKey, root: root,
                expectedSnapshots: [name: original]
            )
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }
}
