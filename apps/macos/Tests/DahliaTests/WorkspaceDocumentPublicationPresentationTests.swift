#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct WorkspaceDocumentPublicationPresentationTests {
        @Test(arguments: [false, true])
        func anOldPublicationCannotCloseAReopenedModal(sameWorkspace: Bool) {
            var presentation = WorkspaceDocumentPublicationPresentation()
            let first = workspace()
            let next = sameWorkspace ? first : workspace()
            presentation.show(first)
            let oldID = presentation.id
            presentation.dismiss()
            presentation.show(next)
            let currentID = presentation.id

            presentation.dismiss(id: oldID)

            #expect(presentation.id == currentID)
            #expect(presentation.workspace == next)
            presentation.dismiss(id: currentID)
            #expect(presentation.workspace == nil)
        }

        private func workspace() -> WorkspaceRecord {
            WorkspaceRecord(id: .v7(), path: nil, name: "Default", createdAt: .now, lastOpenedAt: .distantPast)
        }
    }
#endif
