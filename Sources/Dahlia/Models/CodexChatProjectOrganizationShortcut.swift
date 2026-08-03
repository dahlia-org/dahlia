import Foundation

enum CodexChatProjectOrganizationShortcut {
    static let periodDays = 30

    static var title: String {
        L10n.chatProjectOrganizationShortcutTitle(periodDays)
    }

    static func prompt(
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let createdFrom = calendar.date(byAdding: .day, value: -periodDays, to: now) ?? now
        return L10n.chatProjectOrganizationShortcutPrompt(
            days: periodDays,
            createdFrom: CodexChatPromptCodec.format(createdFrom),
            createdBefore: CodexChatPromptCodec.format(now)
        )
    }
}
