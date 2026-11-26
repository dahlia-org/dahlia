import SwiftUI

/// Makes a new agent or changes one's name and picture, as a card over the window. A new agent also takes what it is
/// and does, its first `SOUL.md`, and can start from a template.
struct AgentEditorView: View {
    @Bindable var model: AgentsModel
    let onCreated: (AgentRecord) -> Void

    @State private var isPickingAvatar = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let draft = Binding(get: { model.draft ?? .init() }, set: { model.draft = $0 })
        let isNew = model.draft?.id == nil
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                ProjectEditorSheetHeader(title: isNew ? L10n.agentNew : L10n.agentEdit, isDisabled: model.isBusy, onClose: cancel)
                HStack(spacing: 14) {
                    Button { isPickingAvatar = true } label: {
                        AgentAvatarView(avatar: draft.wrappedValue.avatar, color: draft.wrappedValue.color, size: 72)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil")
                                    .dahliaFixedSymbol()
                                    .padding(5)
                                    .background(.background, in: .circle)
                                    .overlay { Circle().strokeBorder(.separator) }
                                    .offset(x: 4, y: 4)
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.agentChangeAvatar)
                    .accessibilityLabel(L10n.agentChangeAvatar)
                    .popover(isPresented: $isPickingAvatar, arrowEdge: .bottom) {
                        AgentAvatarPicker(avatar: draft.avatar, color: draft.color)
                    }
                    TextField(L10n.agentName, text: draft.name, prompt: Text(L10n.agentName))
                        .textFieldStyle(.plain)
                        .font(.dahliaTitle2)
                        .focused($isNameFocused)
                }
                if isNew {
                    TextEditor(text: draft.soul)
                        .font(.dahliaBody)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 140)
                        .overlay(alignment: .topLeading) {
                            if draft.wrappedValue.soul.isEmpty {
                                Text(L10n.agentSoulPlaceholder)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(DahliaDesign.contentHighlightColor, in: .rect(cornerRadius: 8))
                        .accessibilityLabel(L10n.agentSoulPlaceholder)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                // As Orca's: the × and the backdrop cancel, so the footer holds only the template menu and the action.
                HStack {
                    Spacer()
                    // The app's own button styles, in its accent, a little taller here as a dialog's main actions.
                    if isNew {
                        Menu {
                            ForEach(AgentTemplate.all) { template in
                                Button(template.name) { model.apply(template) }
                            }
                        } label: {
                            Label(L10n.agentTemplates, systemImage: "square.grid.2x2").padding(.vertical, 3)
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.dahlia(.secondary))
                        .fixedSize()
                    }
                    Button(action: save) {
                        Text(isNew ? L10n.agentCreate : L10n.save).frame(minWidth: 64).padding(.vertical, 3)
                    }
                    .buttonStyle(.dahlia(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBusy || draft.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 520)
            .dahliaModalSurface()
        }
        .transition(.identity)
        .onAppear { isNameFocused = true }
        .onExitCommand(perform: cancel)
    }

    private func save() {
        Task {
            if let created = await model.save() { onCreated(created) }
        }
    }

    private func cancel() {
        guard !model.isBusy else { return }
        model.draft = nil
        model.error = nil
    }
}
