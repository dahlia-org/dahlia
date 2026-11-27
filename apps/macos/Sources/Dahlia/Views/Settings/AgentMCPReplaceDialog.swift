import SwiftUI

/// Asks before a connector takes a name another one holds: replace that one, or register under another name.
struct AgentMCPReplaceDialog: View {
    private enum Choice: Hashable { case replace, alias }

    let message: String
    /// The other name offered first; nil when only one may exist, as for Omnigent.
    let suggestedAlias: String?
    let onReplace: () throws -> Void
    let onAlias: (String) throws -> Void
    let onClose: () -> Void
    @State private var choice = Choice.replace
    @State private var alias = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.mcpNameConflictTitle)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if suggestedAlias != nil {
                    DahliaSegmentedPicker(title: L10n.mcpNameConflictChoice, selection: $choice, options: [.replace, .alias]) {
                        $0 == .replace ? L10n.mcpNameConflictReplace : L10n.mcpNameConflictAlias
                    }
                    if choice == .alias {
                        TextField(L10n.mcpDirectName, text: $alias, prompt: Text(suggestedAlias ?? ""))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(confirm)
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(L10n.cancel, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(choice == .replace ? L10n.mcpNameConflictReplace : L10n.add, action: confirm)
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(choice == .alias && alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 480)
            .dahliaModalSurface()
        }
        .transition(.identity)
        .onAppear { alias = suggestedAlias ?? "" }
    }

    private func confirm() {
        do {
            if choice == .replace {
                try onReplace()
            } else {
                try onAlias(alias.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension AgentMCPReplaceDialog {
    /// Turning `service` on would take `existing`'s name; `enable` turns it on under a name or in `existing`'s place.
    init(
        service: String,
        existing: AgentMCPServer,
        model: AgentMCPSettingsModel,
        enable: @escaping (_ name: String?, _ replacing: AgentMCPServer?) throws -> Void,
        onClose: @escaping () -> Void
    ) {
        let place = existing.direct != nil
            ? L10n.mcpDirectSection
            : L10n.unityGatewayHost(existing.providerID.flatMap { model.settings.provider(id: $0)?.host } ?? existing.providerID ?? "")
        self.init(
            message: L10n.mcpNameConflictMessage(existing.name, place),
            suggestedAlias: model.settings.defaultName(for: service),
            onReplace: { try enable(nil, existing) },
            onAlias: { try enable($0, nil) },
            onClose: onClose
        )
    }
}
