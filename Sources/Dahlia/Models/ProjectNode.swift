import Foundation

/// サイドバー表示用のフラット化されたプロジェクト行。
struct FlatProjectRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let displayName: String
    let depth: Int
    let hasChildren: Bool
    let missingOnDisk: Bool

    /// ProjectRecord 配列から、入力順を保ったままサイドバー表示用のフラット行を構築する。
    static func buildRows(fromRecords records: [ProjectRecord]) -> [FlatProjectRow] {
        guard !records.isEmpty else { return [] }

        let parentNames = parentNames(in: records)
        var rows: [FlatProjectRow] = []
        rows.reserveCapacity(records.count)

        for record in records {
            let components = record.name.split(separator: "/")
            let displayName = components.last.map(String.init) ?? record.name
            let depth = max(components.count - 1, 0)
            let hasChildren = parentNames.contains(record.name)

            rows.append(
                FlatProjectRow(
                    id: record.id,
                    name: record.name,
                    displayName: displayName,
                    depth: depth,
                    hasChildren: hasChildren,
                    missingOnDisk: record.missingOnDisk
                )
            )
        }

        return rows
    }

    /// この行の全祖先パスを返す。例: "a/b/c" → ["a", "a/b"]
    func parentPaths() -> [String] {
        let components = name.split(separator: "/")
        guard components.count > 1 else { return [] }
        return (1 ..< components.count).map { depth in
            components[0 ..< depth].joined(separator: "/")
        }
    }

    private static func parentNames(in records: [ProjectRecord]) -> Set<String> {
        var parentNames = Set<String>()

        for record in records {
            let components = record.name.split(separator: "/")
            guard components.count > 1 else { continue }

            for depth in 1 ..< components.count {
                parentNames.insert(components[0 ..< depth].joined(separator: "/"))
            }
        }

        return parentNames
    }
}

/// SwiftUI の OutlineGroup に渡すプロジェクトツリー行。
struct ProjectTreeNode: Identifiable, Equatable {
    let project: ProjectOverviewItem
    let displayName: String
    let meetingCount: Int
    let children: [ProjectTreeNode]?

    var id: UUID { project.projectId }

    static func buildNodes(from projects: [ProjectOverviewItem]) -> [ProjectTreeNode] {
        guard !projects.isEmpty else { return [] }

        let projectNames = Set(projects.map(\.projectName))
        var roots: [ProjectOverviewItem] = []
        var childrenByParent: [String: [ProjectOverviewItem]] = [:]

        for project in projects {
            guard let parentName = parentName(for: project.projectName),
                  projectNames.contains(parentName) else {
                roots.append(project)
                continue
            }

            childrenByParent[parentName, default: []].append(project)
        }

        func buildNode(for project: ProjectOverviewItem) -> ProjectTreeNode {
            let childNodes = childrenByParent[project.projectName, default: []].map(buildNode)
            let hasParent = parentName(for: project.projectName).map(projectNames.contains) ?? false
            let totalMeetingCount = project.meetingCount + childNodes.reduce(0) { $0 + $1.meetingCount }

            return ProjectTreeNode(
                project: project,
                displayName: displayName(for: project.projectName, hasParent: hasParent),
                meetingCount: totalMeetingCount,
                children: childNodes.isEmpty ? nil : childNodes
            )
        }

        return roots.map(buildNode)
    }

    func filtered(matching query: String) -> ProjectTreeNode? {
        let childNodes = children?.compactMap { $0.filtered(matching: query) } ?? []
        guard matches(query) || !childNodes.isEmpty else { return nil }

        return ProjectTreeNode(
            project: project,
            displayName: displayName,
            meetingCount: meetingCount,
            children: childNodes.isEmpty ? nil : childNodes
        )
    }

    private func matches(_ query: String) -> Bool {
        project.projectName.localizedStandardContains(query)
            || displayName.localizedStandardContains(query)
    }

    private static func parentName(for name: String) -> String? {
        let components = name.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private static func displayName(for name: String, hasParent: Bool) -> String {
        guard hasParent,
              let leafName = name.split(separator: "/").last else { return name }
        return String(leafName)
    }
}
