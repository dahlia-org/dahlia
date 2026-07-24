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

        let parentIDs = Set(records.compactMap(\.parentProjectId))
        var rows: [FlatProjectRow] = []
        rows.reserveCapacity(records.count)

        for record in records {
            let components = record.name.split(separator: "/")
            let displayName = record.leafName
            let depth = max(components.count - 1, 0)
            let hasChildren = parentIDs.contains(record.id)

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

        var roots: [ProjectOverviewItem] = []
        var childrenByParent: [UUID: [ProjectOverviewItem]] = [:]

        for project in projects {
            guard let parentProjectId = project.parentProjectId else {
                roots.append(project)
                continue
            }

            childrenByParent[parentProjectId, default: []].append(project)
        }

        func buildNode(for project: ProjectOverviewItem) -> ProjectTreeNode {
            let childNodes = childrenByParent[project.projectId, default: []].map(buildNode)
            let totalMeetingCount = project.meetingCount + childNodes.reduce(0) { $0 + $1.meetingCount }

            return ProjectTreeNode(
                project: project,
                displayName: project.projectLeafName.nilIfBlank
                    ?? project.projectName.split(separator: "/").last.map(String.init)
                    ?? project.projectName,
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

}
