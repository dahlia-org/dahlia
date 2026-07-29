import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatPresetSkillInputTests {
        @Test
        func explicitPresetSkillIsInjectedOnceWithInstalledPath() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = CodexAppServerService(transportFactory: { transport })
            let homeURL = URL(filePath: "/tmp/dahlia-codex-home", directoryHint: .isDirectory)
            let service = makeService(appServer: appServer, homeURL: homeURL)

            _ = try await service.send(
                threadID: "thread-1",
                inputs: [
                    .text("Meeting context"),
                    .text("Use $projects-optimizer to organize recent meetings."),
                    .text("$projects-optimizer"),
                ],
                model: "default-model",
                effort: "medium"
            )

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["input"] == .array([
                .object(["type": .string("text"), "text": .string("Meeting context")]),
                .object([
                    "type": .string("text"),
                    "text": .string("Use $projects-optimizer to organize recent meetings."),
                ]),
                .object(["type": .string("text"), "text": .string("$projects-optimizer")]),
                skillInput(homeURL: homeURL),
            ]))
            await appServer.shutdown()
        }

        @Test
        func similarPresetSkillNameDoesNotInjectSkill() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = CodexAppServerService(transportFactory: { transport })
            let service = makeService(
                appServer: appServer,
                homeURL: URL(filePath: "/tmp/dahlia-codex-home", directoryHint: .isDirectory)
            )

            _ = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Use $projects-optimizer-extra.")],
                model: "default-model",
                effort: "medium"
            )

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["input"] == .array([
                .object(["type": .string("text"), "text": .string("Use $projects-optimizer-extra.")]),
            ]))
            await appServer.shutdown()
        }

        @Test
        func steeringInjectsExplicitPresetSkill() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = CodexAppServerService(transportFactory: { transport })
            let homeURL = URL(filePath: "/tmp/dahlia-codex-home", directoryHint: .isDirectory)
            let service = makeService(appServer: appServer, homeURL: homeURL)

            try await service.steer(
                threadID: "thread-1",
                turnID: "turn-1",
                inputs: [.text("$projects-optimizerで整理を続けて")]
            )

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/steer"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["input"] == .array([
                .object(["type": .string("text"), "text": .string("$projects-optimizerで整理を続けて")]),
                skillInput(homeURL: homeURL),
            ]))
            await appServer.shutdown()
        }

        private func makeService(appServer: CodexAppServerService, homeURL: URL) -> CodexChatService {
            CodexChatService(
                appServer: appServer,
                workspaceLocator: TestWorkspaceLocator(),
                homeLocator: TestHomeLocator(url: homeURL)
            )
        }

        private func skillInput(homeURL: URL) -> JSONValue {
            .object([
                "name": .string("projects-optimizer"),
                "path": .string(homeURL.appending(path: "skills/projects-optimizer/SKILL.md").path),
                "type": .string("skill"),
            ])
        }
    }

    private struct TestWorkspaceLocator: CodexChatWorkspaceLocating {
        func workspaceURL(vaultID: UUID) throws -> URL {
            URL(filePath: "/tmp/dahlia-chat-tests/\(vaultID.uuidString.lowercased())")
        }
    }

    private struct TestHomeLocator: CodexHomeLocating {
        let url: URL

        func homeURL() throws -> URL {
            url
        }
    }
#endif
