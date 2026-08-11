import Foundation

protocol CodexPresetSkillInstalling: Sendable {
    func install(into homeURL: URL) throws
}

struct BundledCodexPresetSkillInstaller: CodexPresetSkillInstalling {
    nonisolated static let skillNames = [
        "projects-optimizer",
        "contacts-organizations-curator",
        "conversation-topics-curator",
        "insights-curator",
    ]
    nonisolated static let obsoleteSkillNames = ["organize-projects-meetings"]

    private static let bundledResourceDirectory = "CodexSkills"

    private static let bundledFilePaths = [
        "SKILL.md",
        "agents/openai.yaml",
    ]

    func install(into homeURL: URL) throws {
        let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)

        do {
            let bundledSkills: [(name: String, files: [(path: String, data: Data)])] = try Self.skillNames
                .map { skillName in
                    let files: [(path: String, data: Data)] = try Self.bundledFilePaths.map { relativePath in
                        let url = try sourceFileURL(skillName: skillName, relativePath: relativePath)
                        return try (relativePath, Data(contentsOf: url))
                    }
                    return (skillName, files)
                }
            try validatePrivateDirectory(homeURL)
            try createPrivateDirectory(skillsURL)
            for obsoleteSkillName in Self.obsoleteSkillNames {
                try removeItemIfPresent(
                    at: skillsURL.appending(path: obsoleteSkillName, directoryHint: .isDirectory)
                )
            }
            for skill in bundledSkills {
                let destinationURL = skillsURL.appending(path: skill.name, directoryHint: .isDirectory)
                try removeItemIfPresent(at: destinationURL)
                try createPrivateDirectory(destinationURL)
                for file in skill.files {
                    let destinationFileURL = destinationURL.appending(path: file.path)
                    try createPrivateDirectory(destinationFileURL.deletingLastPathComponent())
                    try file.data.write(to: destinationFileURL, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: destinationFileURL.path
                    )
                }
            }
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }

    private func sourceFileURL(skillName: String, relativePath: String) throws -> URL {
        var components = relativePath.split(separator: "/").map(String.init)
        let fileName = URL(filePath: components.removeLast())
        let subdirectory = ([Self.bundledResourceDirectory, skillName] + components).joined(separator: "/")
        guard let url = Bundle.appModule.url(
            forResource: fileName.deletingPathExtension().lastPathComponent,
            withExtension: fileName.pathExtension,
            subdirectory: subdirectory
        ) else {
            throw CodexAppServerError.launchFailed("The bundled Codex preset skill \(skillName) is missing.")
        }
        return url
    }

    private func createPrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try validatePrivateDirectory(url)
        } else {
            if isSymbolicLink(url) {
                throw CodexAppServerError.launchFailed("A Codex skill directory is a symbolic link.")
            }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try validatePrivateDirectory(url)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CodexAppServerError.launchFailed("A Codex skill directory is not a private directory.")
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
