import Foundation

/// The skill is the list identity, including archived or unavailable skills that still have change history.
struct AgentSkillSettingsEntry: Identifiable, Sendable {
    let name: String
    let skill: CodexChatSlashCommand?
    let provenance: SkillProvenance
    var id: String { name }
    var isReadOnly: Bool { provenance != .account }

    static func grouped(skills: [CodexChatSlashCommand], changes: [AgentLearningChangeRecord], root: URL) -> [Self] {
        let catalog = Dictionary(skills.map { ($0.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(catalog.keys).union(changes.lazy.filter { $0.kind == "skill" }.map(\.target))
        return names.sorted().map { name in
            let skill = catalog[name]
            let file = skill?.skillFileURL.map { URL(filePath: PiSandbox.realPath($0)) }
            return Self(name: name, skill: skill, provenance: .of(name: name, file: file, root: root))
        }
    }
}
