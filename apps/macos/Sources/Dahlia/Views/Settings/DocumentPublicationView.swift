import GRDB
import SwiftUI

struct DocumentPublicationView: View {
    let workspace: WorkspaceRecord
    let dbQueue: DatabaseQueue
    let close: () -> Void
    @State private var candidates: [DocumentPublication.Candidate] = []
    @State private var archives: [(UUID, String, String)] = []
    @State private var loading = true
    @State private var publishing = false
    @State private var message = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { if !publishing { close() } }
            VStack(alignment: .leading, spacing: 16) {
                Text(workspace.accountConnectionId == nil ? L10n.documentPrivateLegacy : L10n.documentPublishTitle).font(.title2)
                Text(workspace.name).font(.headline)
                if workspace.accountConnectionId != nil { Text(L10n.documentPublishAudience).fixedSize(horizontal: false, vertical: true) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(archives, id: \.0) { entry in
                            DisclosureGroup(entry.1) { Text(entry.2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        ForEach(candidates) { candidate in
                            DisclosureGroup(candidate.name) {
                                Text(candidate.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                if loading { ProgressView() }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button(L10n.cancel) { close() }.disabled(publishing)
                    Button(L10n.documentPublishTitle) {
                        publishing = true
                        Task {
                            do {
                                guard let connectionID = workspace.accountConnectionId else { throw DocumentCoreError.unavailable }
                                let conflicts = try await DocumentPublication.publish(
                                    candidates,
                                    workspaceID: workspace.id,
                                    connectionID: connectionID,
                                    dbQueue: dbQueue
                                )
                                if conflicts.isEmpty {
                                    close()
                                } else {
                                    message = L10n.documentPublishConflict + "\n" + conflicts.joined(separator: "\n")
                                }
                            } catch { message = L10n.documentSyncFailed }
                            publishing = false
                        }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(publishing || loading || candidates.isEmpty || !workspace.allowsCanonicalEdits || workspace.accountConnectionId == nil)
                }
            }
            .padding(24)
            .frame(width: 520)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
        .task {
            do {
                archives = try await DocumentPersistence.shared(dbQueue: dbQueue).archives(workspaceID: workspace.id)
                if workspace.accountConnectionId != nil { candidates = try await DocumentPublication.candidates(
                    workspaceID: workspace.id,
                    dbQueue: dbQueue
                ) }
            } catch { message = L10n.documentSaveFailed }
            loading = false
        }
    }
}
