import Foundation

@MainActor
final class MeetingLinkOpener {
    private let settings: any MeetingLinkOpenSettingsProviding
    private let workspace: any MeetingLinkWorkspaceOpening

    init(
        settings: any MeetingLinkOpenSettingsProviding = AppSettings.shared,
        workspace: any MeetingLinkWorkspaceOpening = SystemMeetingLinkWorkspace()
    ) {
        self.settings = settings
        self.workspace = workspace
    }

    /// リンクを開いたアプリの bundle identifier を返す。開けなかった場合は nil、開けたがアプリが分からない場合は空文字列。
    @discardableResult
    func open(_ url: URL) -> Task<String?, Never> {
        let targets = targets(for: url)
        let workspace = workspace
        return Task.detached(priority: .userInitiated) {
            await Self.open(url, using: targets, workspace: workspace)
        }
    }

    private func targets(for url: URL) -> [MeetingLinkOpenTarget] {
        let globalTarget = settings.defaultMeetingLinkOpenTarget
        guard let service = MeetingLinkService(conferenceURL: url) else {
            return Self.uniqueTargets([globalTarget, .systemDefault])
        }

        switch settings.meetingLinkOpenTarget(for: service) {
        case .inheritGlobal:
            return Self.uniqueTargets([globalTarget, .systemDefault])
        case .systemDefault:
            return [.systemDefault]
        case let .application(bundleIdentifier):
            return Self.uniqueTargets([
                .application(bundleIdentifier: bundleIdentifier),
                globalTarget,
                .systemDefault,
            ])
        }
    }

    private static func uniqueTargets(_ targets: [MeetingLinkOpenTarget]) -> [MeetingLinkOpenTarget] {
        var seen: Set<MeetingLinkOpenTarget> = []
        return targets.filter { target in
            target != .inheritGlobal && seen.insert(target).inserted
        }
    }

    private nonisolated static func open(
        _ url: URL,
        using targets: [MeetingLinkOpenTarget],
        workspace: any MeetingLinkWorkspaceOpening
    ) async -> String? {
        for target in targets {
            let openedApplication: String?
            switch target {
            case .inheritGlobal:
                continue
            case .systemDefault:
                openedApplication = await workspace.open(url, withApplicationAt: nil)
            case let .application(bundleIdentifier):
                guard let applicationURL = await workspace.applicationURL(forBundleIdentifier: bundleIdentifier) else {
                    continue
                }
                openedApplication = await workspace.open(url, withApplicationAt: applicationURL)
            }
            if let openedApplication {
                return openedApplication
            }
        }
        return nil
    }
}
