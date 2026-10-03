import SwiftUI

struct DocumentEditorStatusView: View {
    let model: DocumentEditorModel
    @State private var showsDetails = false

    private var title: String {
        if !model.error.isEmpty { return model.error }
        return model.status.isEmpty ? L10n.notes : model.status
    }

    var body: some View {
        CodexChatIconButton(
            label: title == L10n.notes ? title : L10n.notes + ": " + title,
            systemImage: model.error.isEmpty ? "doc.text" : "exclamationmark.triangle",
            size: DahliaDesign.windowHeaderControlSize
        ) {
            showsDetails.toggle()
        }
        .foregroundStyle(model.error.isEmpty ? Color.secondary : Color.orange)
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).textSelection(.enabled)
                if !model.people.isEmpty {
                    Text(L10n.documentEditing + model.people.joined(separator: ", "))
                }
                if model.canRetrySynchronization {
                    Button(L10n.retry) {
                        Task { await model.retryVisibleDocument() }
                    }
                }
            }
            .font(.callout)
            .padding()
            .frame(width: 300, alignment: .leading)
        }
    }
}
