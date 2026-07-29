import Foundation

protocol CodexPresetSkillInstalling: Sendable {
    func install(into homeURL: URL) throws
}

struct BundledCodexPresetSkillInstaller: CodexPresetSkillInstalling {
    nonisolated static let skillName = "projects-optimizer"
    nonisolated static let obsoleteSkillName = "organize-projects-meetings"

    private static let bundledFilePaths = [
        "SKILL.md",
        "agents/openai.yaml",
    ]

    nonisolated static func skillFileURL(in homeURL: URL) -> URL {
        homeURL
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: skillName, directoryHint: .isDirectory)
            .appending(path: "SKILL.md")
    }

    func install(into homeURL: URL) throws {
        let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)
        let destinationURL = Self.skillFileURL(in: homeURL).deletingLastPathComponent()
        let obsoleteSkillURL = skillsURL
            .appending(path: Self.obsoleteSkillName, directoryHint: .isDirectory)

        do {
            let bundledFiles = try Self.bundledFilePaths.map { relativePath in
                try (relativePath, Data(contentsOf: sourceFileURL(relativePath: relativePath)))
            }
            try validatePrivateDirectory(homeURL)
            try createPrivateDirectory(skillsURL)
            try removeItemIfPresent(at: obsoleteSkillURL)
            try removeItemIfPresent(at: destinationURL)
            try createPrivateDirectory(destinationURL)
            for (relativePath, data) in bundledFiles {
                let destinationFileURL = destinationURL.appending(path: relativePath)
                try createPrivateDirectory(destinationFileURL.deletingLastPathComponent())
                try data.write(to: destinationFileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationFileURL.path
                )
            }
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }

    private func sourceFileURL(relativePath: String) throws -> URL {
        let relativeURL = URL(filePath: relativePath)
        let resourceName = relativeURL.deletingPathExtension().lastPathComponent
        let resourceExtension = relativeURL.pathExtension
        guard let url = Bundle.appModule.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw CodexAppServerError.launchFailed("The bundled Codex preset skill is missing.")
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
