import SwiftUI

struct DocumentRecoveryHistoryView: View {
    let model: DocumentEditorModel
    let editable: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.documentRecoveryTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.recoveries, id: \.id) { recovery in
                        row(recovery)
                        Divider()
                    }
                }
                .padding(.horizontal, 20)
            }
            .overlay {
                if model.recoveries.isEmpty {
                    Text(L10n.documentRecoveryEmpty)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }

            Divider()

            HStack {
                Button(L10n.documentHistoryPrevious, action: model.previousRecoveryPage)
                    .disabled(!model.recoveryPrevious)
                Button(L10n.documentHistoryNext, action: model.nextRecoveryPage)
                    .disabled(model.recoveryNext == nil)
                Spacer()
                Button(L10n.close, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.setRecoveryOpen(true) }
        .onDisappear { model.setRecoveryOpen(false) }
    }

    private func row(_ recovery: DocumentRecoveryRecord) -> some View {
        let fullText = model.fullRecovery?.id == recovery.id ? model.fullRecovery?.text : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(fullText ?? model.recoveryText[recovery.id] ?? "")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if fullText == nil {
                    Button(L10n.documentHistoryFullText) { model.showRecovery(recovery) }
                }
                if editable {
                    Button(L10n.documentRestore) {
                        model.restore(recovery)
                        onClose()
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 12)
    }
}

private struct DocumentRecoveryHistoryPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: DocumentEditorModel?
    let editable: Bool

    func body(content: Content) -> some View {
        let presentedModel = isPresented ? model : nil
        return ZStack {
            content
                .disabled(presentedModel != nil)
                .accessibilityHidden(presentedModel != nil)

            if let presentedModel {
                Button(action: dismiss) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)

                DocumentRecoveryHistoryView(model: presentedModel, editable: editable, onClose: dismiss)
                    .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
                    .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
            }
        }
        .transition(.identity)
        .onChange(of: model.map { ObjectIdentifier($0) }) { dismiss() }
    }

    private func dismiss() {
        isPresented = false
    }
}

extension View {
    func documentRecoveryHistoryPresentation(
        isPresented: Binding<Bool>,
        model: DocumentEditorModel?,
        editable: Bool
    ) -> some View {
        modifier(DocumentRecoveryHistoryPresentationModifier(isPresented: isPresented, model: model, editable: editable))
    }
}
