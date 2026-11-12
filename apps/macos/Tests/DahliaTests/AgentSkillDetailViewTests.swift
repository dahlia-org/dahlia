@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AgentSkillDetailViewTests {
        @Test(arguments: ["\n", "\r\n"])
        func hidesOnlyLeadingFrontmatter(newline: String) {
            let body = "# Skill\(newline)\(newline)Instructions\(newline)---\(newline)More instructions"
            let text = ["---", "name: Skill", "description: Description", "---", body].joined(separator: newline)
            #expect(AgentSkillDetailView.markdownBody(from: text) == body)
        }

        @Test(arguments: ["", "# Skill\n---\nInstructions", "---\nname: Skill\nInstructions", "---\nname: Skill\n--- not a delimiter\nInstructions"])
        func preservesContentWithoutCompleteFrontmatter(text: String) {
            #expect(AgentSkillDetailView.markdownBody(from: text) == text)
        }

        @Test
        func handlesEmptyFrontmatterAndMissingBody() {
            #expect(AgentSkillDetailView.markdownBody(from: "---\n---\n# Skill") == "# Skill")
            #expect(AgentSkillDetailView.markdownBody(from: "---\nname: Skill\n---").isEmpty)
        }
    }
#endif
