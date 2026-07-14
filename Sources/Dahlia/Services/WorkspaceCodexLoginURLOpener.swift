import AppKit

@MainActor
struct WorkspaceCodexLoginURLOpener: CodexLoginURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
