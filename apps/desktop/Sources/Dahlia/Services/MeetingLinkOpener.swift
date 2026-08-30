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

    @discardableResult
    func open(_ url: URL) -> Task<Bool, Never> {
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
    ) async -> Bool {
        for target in targets {
            let didOpen: Bool
            switch target {
            case .inheritGlobal:
                continue
            case .systemDefault:
                didOpen = await workspace.open(url, withApplicationAt: nil)
            case let .application(bundleIdentifier):
                guard let applicationURL = await workspace.applicationURL(forBundleIdentifier: bundleIdentifier) else {
                    continue
                }
                didOpen = await workspace.open(url, withApplicationAt: applicationURL)
            }
            if didOpen {
                return true
            }
        }
        return false
    }
}
