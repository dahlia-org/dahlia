import Foundation

struct WorkspaceDocumentPublicationPresentation {
    private(set) var id = UUID.v7()
    private(set) var workspace: WorkspaceRecord?

    mutating func show(_ workspace: WorkspaceRecord) {
        id = .v7()
        self.workspace = workspace
    }

    mutating func dismiss(id: UUID) {
        guard self.id == id else { return }
        dismiss()
    }

    mutating func dismiss() {
        workspace = nil
    }
}
