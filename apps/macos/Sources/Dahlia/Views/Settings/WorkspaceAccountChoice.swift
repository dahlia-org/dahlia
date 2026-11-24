import Foundation

/// The account a workspace is listed under: the app's, whose data stays on this Mac. No workspace belongs to a
/// Dahlia account or a Databricks connection.
enum WorkspaceAccountChoice: Hashable {
    case local

    init(_: WorkspaceRecord) {
        self = .local
    }

    var displayName: String { L10n.localAccount }
}
