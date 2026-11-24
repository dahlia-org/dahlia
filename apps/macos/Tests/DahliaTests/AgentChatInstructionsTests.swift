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
                AgentChatInstructionsSection(defaults: defaults)
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
                AgentChatInstructions.load(defaults: defaults) == "日本語で回答してください"
            })
            #expect(textView.string == "日本語で回答してください")
        }

        @Test
        func summaryOptInIgnoresBlankInstructions() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("Focus on decisions", forKey: AgentChatInstructions.defaultsKey())
            #expect(AgentChatInstructions.loadForSummary(defaults: defaults) == nil)
            defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey())
            #expect(AgentChatInstructions.loadForSummary(defaults: defaults) == "Focus on decisions")
            defaults.set(false, forKey: AgentChatInstructions.summaryEnabledKey())
            #expect(AgentChatInstructions.loadForSummary(defaults: defaults) == nil)
            #expect(AgentChatInstructions.load(defaults: defaults) == "Focus on decisions")
            defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey())
            for blank in ["", " \n\t"] {
                defaults.set(blank, forKey: AgentChatInstructions.defaultsKey())
                #expect(AgentChatInstructions.loadForSummary(defaults: defaults) == nil)
            }
        }

        @Test
        func summaryCapturesInstructionsAndPreservesThemAcrossOptionsAndPersistence() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now)
            defaults.set("Focus on decisions", forKey: AgentChatInstructions.defaultsKey())
            let disabled = SummaryGenerationSettings.current(workspace: workspace, defaults: defaults)
            #expect(disabled.customInstructions == nil)
            #expect(!SummaryService.summaryGenerationInstructions(generationSettings: disabled).contains("Focus on decisions"))
            defaults.set(true, forKey: AgentChatInstructions.summaryEnabledKey())
            let captured = SummaryGenerationSettings.current(workspace: workspace, defaults: defaults)
            defaults.set("Changed after capture", forKey: AgentChatInstructions.defaultsKey())
            defaults.set(false, forKey: AgentChatInstructions.summaryEnabledKey())
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
        func instructionsPersistAndCanBeCleared() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            #expect(AgentChatInstructions.load(defaults: defaults).isEmpty)
            defaults.set("Instructions\n日本語", forKey: AgentChatInstructions.defaultsKey())
            let reloaded = try #require(UserDefaults(suiteName: suite))
            #expect(AgentChatInstructions.load(defaults: reloaded) == "Instructions\n日本語")
            defaults.set("", forKey: AgentChatInstructions.defaultsKey())
            #expect(AgentChatInstructions.load(defaults: defaults).isEmpty)
        }
    }
#endif
