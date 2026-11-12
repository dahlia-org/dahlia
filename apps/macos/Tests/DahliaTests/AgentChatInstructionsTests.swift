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
