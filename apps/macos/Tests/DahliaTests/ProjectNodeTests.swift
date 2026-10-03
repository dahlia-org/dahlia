import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct ProjectNodeTests {
        @Test
        func marksDirectParentAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo/bar"])
            )

            #expect(rows.map(\.hasChildren) == [true, false])
        }

        @Test
        func ignoresSiblingPrefixesWhenDeterminingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo-archive", "foo/bar"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func ignoresNonDescendantPrefixMatches() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo", "foo.bar", "foo/bar", "foo0"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false, false])
        }

        @Test
        func marksRootAsHavingChildren() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["a", "a/b", "z"])
            )

            #expect(rows.map(\.hasChildren) == [true, false, false])
        }

        @Test
        func keepsInputOrderWhileComputingChildrenIndependently() {
            let rows = FlatProjectRow.buildRows(
                fromRecords: projects(named: ["foo/bar", "foo", "foo/baz"])
            )

            #expect(rows.map(\.name) == ["foo/bar", "foo", "foo/baz"])
            #expect(rows.map(\.hasChildren) == [false, true, false])
        }

        @Test
        func projectParentCandidatesContainOnlyOtherRoots() throws {
            let records = projects(named: ["alpha", "alpha/work", "beta", "beta/work"])
            let rows = FlatProjectRow.buildRows(fromRecords: records)
            let child = try #require(records.first(where: { $0.path == "alpha/work" }))

            let candidates = FlatProjectRow.validParentCandidates(for: child, in: rows)

            #expect(candidates.map(\.name) == ["alpha", "beta"])
        }

        @Test
        func projectWithChildrenCannotSelectANewParent() throws {
            let records = projects(named: ["alpha", "alpha/work", "beta"])
            let rows = FlatProjectRow.buildRows(fromRecords: records)
            let root = try #require(records.first(where: { $0.path == "alpha" }))

            #expect(FlatProjectRow.validParentCandidates(for: root, in: rows).isEmpty)
        }

        @Test
        func buildsOneLevelProjectTreeWithAggregateMeetingCounts() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [
                    ("foo", 2), ("foo/bar", 3), ("z", 4),
                ])
            )

            #expect(nodes.map(\.displayName) == ["foo", "z"])
            #expect(nodes.map(\.meetingCount) == [5, 4])
            #expect(nodes.first?.children?.map(\.displayName) == ["bar"])
            #expect(nodes.first?.children?.first?.meetingCount == 3)
        }

        @Test
        func filtersProjectTreeKeepingAncestorsAndAggregateCounts() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [
                    ("foo", 2), ("foo/bar", 3), ("z", 4),
                ])
            )
            let filteredNodes = nodes.compactMap { $0.filtered(matching: "bar") }

            #expect(filteredNodes.map(\.displayName) == ["foo"])
            #expect(filteredNodes.first?.meetingCount == 5)
            #expect(filteredNodes.first?.children?.map(\.displayName) == ["bar"])
            #expect(filteredNodes.first?.children?.first?.meetingCount == 3)
        }

        @Test
        func projectSearchUsesLocalizedStandardMatching() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [
                    ("Café", 0), ("Café/Planning", 2), ("Archive", 1),
                ])
            )

            let filteredNodes = nodes.compactMap { $0.filtered(matching: "cafe") }

            #expect(filteredNodes.map(\.displayName) == ["Café"])
            #expect(filteredNodes.first?.children?.map(\.displayName) == ["Planning"])
        }

        @Test
        func projectSearchReturnsNoNodesForUnmatchedQuery() {
            let nodes = ProjectTreeNode.buildNodes(
                from: projectOverviews(named: [("Alpha", 0), ("Alpha/Beta", 1)])
            )

            #expect(nodes.compactMap { $0.filtered(matching: "Gamma") }.isEmpty)
        }

        @Test
        func projectFolderSafetyRejectsAncestorSymlinkOutsideWorkspace() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-project-folder-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            let workspaceURL = rootURL.appending(path: "Workspace", directoryHint: .isDirectory)
            let outsideURL = rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: outsideURL.appending(path: "Child", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: workspaceURL.appending(path: "Root", directoryHint: .isDirectory),
                withDestinationURL: outsideURL
            )

            #expect(!ProjectFolderSafety.isSafeDirectory(
                workspaceURL.appending(path: "Root/Child", directoryHint: .isDirectory),
                inside: workspaceURL
            ))
        }

        @Test
        func projectFolderSafetyDistinguishesMissingAndAvailableDirectories() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-project-folder-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            let workspaceURL = rootURL.appending(path: "Workspace", directoryHint: .isDirectory)
            let availableURL = workspaceURL.appending(path: "Existing", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: availableURL, withIntermediateDirectories: true)

            #expect(ProjectFolderSafety.status(of: availableURL, inside: workspaceURL) == .available)
            #expect(ProjectFolderSafety.status(
                of: workspaceURL.appending(path: "Not Created", directoryHint: .isDirectory),
                inside: workspaceURL
            ) == .missing)
        }

        private func projects(named names: [String]) -> [ProjectRecord] {
            let ids = Dictionary(uniqueKeysWithValues: names.map { ($0, UUID.v7()) })
            let workspaceID = UUID.v7()
            return names.map { name in
                let components = name.split(separator: "/")
                let parentPath = components.dropLast().joined(separator: "/")
                return ProjectRecord(
                    id: ids[name]!,
                    workspaceId: workspaceID,
                    parentProjectId: parentPath.isEmpty ? nil : ids[parentPath],
                    name: String(components.last!),
                    createdAt: Date(),
                    projectType: parentPath.isEmpty ? .undefined : nil,
                    resolvedPath: name
                )
            }
        }

        private func projectOverviews(named values: [(String, Int)]) -> [ProjectOverviewItem] {
            let ids = Dictionary(uniqueKeysWithValues: values.map { ($0.0, UUID.v7()) })
            return values.map { name, meetingCount in
                let components = name.split(separator: "/")
                let parentPath = components.dropLast().joined(separator: "/")
                return ProjectOverviewItem(
                    projectId: ids[name]!,
                    projectName: name,
                    projectDisplayName: String(components.last!),
                    parentProjectId: parentPath.isEmpty ? nil : ids[parentPath],
                    createdAt: Date(),
                    meetingCount: meetingCount,
                    latestMeetingDate: nil
                )
            }
        }
    }

#endif
