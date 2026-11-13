import Foundation
import AppKit
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AgentChatInstructionsTests {
        @Test
        func editorStartsEmptyOnTheLeftAndSavesTypedText() async throws {
            let suite = "AgentChatInstructionsTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = NSHostingView(rootView: Form {
                AgentChatInstructionsSection(account: .local, defaults: defaults)
            }.formStyle(.grouped).font(.dahliaBody))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            func editor(in view: NSView) -> NSTextView? {
                (view as? NSTextView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
            }
            let textView = try #require(editor(in: host))
            #expect(textView.string.isEmpty)
            #expect(textView.alignment == .left || textView.alignment == .natural)
            textView.insertText("日本語で回答してください", replacementRange: NSRange(location: 0, length: 0))
            #expect(await pollUntil {
                AgentChatInstructions.load(for: .local, defaults: defaults) == "日本語で回答してください"
            })
            #expect(textView.string == "日本語で回答してください")
        }

        @Test
        func summaryOptInIsAccountLocalAndIgnoresBlankInstructions() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts: [CodexRuntimeProvider] = [.local, .dahlia(connectionID: .v7()), .databricks(connectionID: .v7())]
            for account in accounts {
                defaults.set("Focus on decisions", forKey: AgentChatInstructions.defaultsKey(for: account))
                #expect(AgentChatInstructions.loadForSummary(for: account, defaults: defaults) == nil)
            }
            for account in accounts {
                defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
                #expect(AgentChatInstructions.loadForSummary(for: account, defaults: defaults) == "Focus on decisions")
                for other in accounts where other != account {
                    #expect(AgentChatInstructions.loadForSummary(for: other, defaults: defaults) == nil)
                }
                defaults.set(false, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
                #expect(AgentChatInstructions.loadForSummary(for: account, defaults: defaults) == nil)
                #expect(AgentChatInstructions.load(for: account, defaults: defaults) == "Focus on decisions")
                defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
                for blank in ["", " \n\t"] {
                    defaults.set(blank, forKey: AgentChatInstructions.defaultsKey(for: account))
                    #expect(AgentChatInstructions.loadForSummary(for: account, defaults: defaults) == nil)
                }
                defaults.set(false, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
            }
        }

        @Test
        func summaryCapturesInstructionsAndPreservesThemAcrossOptionsAndPersistence() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now)
            workspace.accountConnectionId = .v7()
            let account = CodexRuntimeProvider(workspace: workspace)
            defaults.set("Focus on decisions", forKey: AgentChatInstructions.defaultsKey(for: account))
            let disabled = SummaryGenerationSettings.current(workspace: workspace, defaults: defaults)
            #expect(disabled.customInstructions == nil)
            #expect(!SummaryService.summaryGenerationInstructions(generationSettings: disabled).contains("Focus on decisions"))
            defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
            let captured = SummaryGenerationSettings.current(workspace: workspace, defaults: defaults)
            defaults.set("Changed after capture", forKey: AgentChatInstructions.defaultsKey(for: account))
            defaults.set(false, forKey: AgentChatInstructions.summaryEnabledKey(for: account))
            let adjusted = captured.applying(detailLevel: .concise).applying(options: .manual)
            let restored = try JSONDecoder().decode(SummaryGenerationSettings.self, from: JSONEncoder().encode(adjusted))
            #expect(restored.customInstructions == "Focus on decisions")
            let prompt = SummaryService.summaryGenerationInstructions(generationSettings: restored)
            #expect(prompt.contains("# User's custom instructions for summary generation\nFocus on decisions"))
            #expect(prompt.hasPrefix(AppSettings.defaultSummaryPrompt))
            #expect(prompt.contains(SummaryService.codexInputTrustInstruction))
            #expect(prompt.hasSuffix(SummaryService.codexStructuredInstruction))
            #expect(!prompt.contains("Changed after capture"))
            let next = SummaryGenerationSettings.current(workspace: workspace, defaults: defaults)
            #expect(next.customInstructions == nil)
            var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
            legacyJSON.removeValue(forKey: "customInstructions")
            let legacy = try JSONDecoder().decode(SummaryGenerationSettings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
            #expect(legacy.customInstructions == nil)
        }

        @Test
        func instructionsPersistPerAccountAndCanBeCleared() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts: [CodexRuntimeProvider] = [.local, .dahlia(connectionID: .v7()), .databricks(connectionID: .v7())]
            for account in accounts {
                #expect(AgentChatInstructions.load(for: account, defaults: defaults).isEmpty)
            }
            for (index, account) in accounts.enumerated() {
                defaults.set("Instructions \(index)\n日本語", forKey: AgentChatInstructions.defaultsKey(for: account))
            }
            let reloaded = try #require(UserDefaults(suiteName: suite))
            for (index, account) in accounts.enumerated() {
                #expect(AgentChatInstructions.load(for: account, defaults: reloaded) == "Instructions \(index)\n日本語")
            }
            defaults.set("", forKey: AgentChatInstructions.defaultsKey(for: .local))
            #expect(AgentChatInstructions.load(for: .local, defaults: defaults).isEmpty)
            #expect(!AgentChatInstructions.load(for: accounts[1], defaults: defaults).isEmpty)
        }
    }
#endif
