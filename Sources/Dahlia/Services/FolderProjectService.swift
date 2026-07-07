import Foundation

/// 保管庫内のプロジェクトフォルダに対するファイルシステム操作を提供する。
struct FolderProjectService {
    private let fileManager = FileManager.default

    // MARK: - CONTEXT

    func contextFileURL(at projectURL: URL) -> URL {
        projectURL.appendingPathComponent("CONTEXT.md")
    }

    /// CONTEXT.md が存在しなければ Obsidian 互換のフロントマッター付きで作成し、URL を返す。
    @discardableResult
    func ensureContextFileExists(at projectURL: URL) -> URL? {
        let url = contextFileURL(at: projectURL)
        guard !fileManager.fileExists(atPath: url.path) else {
            return url
        }

        let content = """
        ---
        tags:
          - customer_meeting
        ---

        # context
        <context>
        This is a meeting with a customer.
        The goal is to understand the customer's industry, organization, project, needs, and concerns,
        and to follow up on that information to increase the customer's usage of the product.
        </context>

        """
        do {
            try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    func readContext(at projectURL: URL) throws -> String {
        let url = contextFileURL(at: projectURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @discardableResult
    func writeContext(_ content: String, at projectURL: URL) throws -> URL {
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let url = contextFileURL(at: projectURL)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}
