#if canImport(Testing)
    import AppKit
    import Foundation
    import Observation
    import os
    import SwiftUI
    import Testing
    @testable import Dahlia

    /// Streams a long Markdown answer into the real chat conversation view and reports main-thread stalls.
    /// Runs only with `DAHLIA_RESPONSIVENESS_BENCHMARK=1`, because it takes tens of seconds and prints numbers instead of asserting a contract.
    @MainActor
    struct ResponsivenessChatStreamingBenchmark {
        @Observable
        @MainActor
        final class Conversation {
            var messages: [CodexChatMessage]
            init(messages: [CodexChatMessage]) { self.messages = messages }
        }

        private struct Host: View {
            let conversation: Conversation
            let coordinator: CodexChatCoordinator
            let id = CodexChatSessionID()

            var body: some View {
                CodexChatConversationView(
                    conversationID: id, messages: conversation.messages, showsStandaloneThinking: false,
                    meetingNamesByID: [:], meetingReferencesByID: [:], contentMaxWidth: 760,
                    hasStoredEarlierMessages: false, isLoadingEarlierMessages: false, canLoadEarlierMessages: false,
                    onLoadEarlierMessages: {}, parentThreadID: nil, currentRunID: nil,
                    coordinator: coordinator, onOpenThread: { _ in }
                )
            }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["DAHLIA_RESPONSIVENESS_BENCHMARK"] == "1"))
        func streamLongMarkdownAnswer() async throws {
            let answer = ResponsivenessFixtureSeeder.longMarkdown(0)
            var history: [CodexChatMessage] = []
            let historyCount = Int(ProcessInfo.processInfo.environment["DAHLIA_BENCHMARK_HISTORY"] ?? "") ?? 6
            for turn in 0 ..< historyCount {
                history.append(CodexChatMessage(role: .user, text: "Question \(turn)"))
                history.append(CodexChatMessage(role: .assistant, text: ResponsivenessFixtureSeeder.longMarkdown(turn + 1)))
            }
            let streamingID = UUID.v7().uuidString
            let conversation = Conversation(messages: history + [
                CodexChatMessage(role: .user, text: "Write the plan."),
                CodexChatMessage(id: streamingID, role: .assistant, text: "", isStreaming: true),
            ])
            let coordinator = CodexChatCoordinator(service: TestCodexChatService(mode: .complete), settings: AppSettings())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let host = NSHostingView(rootView: Host(conversation: conversation, coordinator: coordinator))
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let stalls = StallProbe()
            stalls.start()
            defer { stalls.stop() }
            var layoutDurations: [Double] = []
            // 2000 characters per second in 20 Hz updates, the rate the streaming limiter publishes at.
            let step = 100
            var end = answer.startIndex
            let started = ContinuousClock.now
            while end < answer.endIndex {
                end = answer.index(end, offsetBy: step, limitedBy: answer.endIndex) ?? answer.endIndex
                let index = try #require(conversation.messages.firstIndex { $0.id == streamingID })
                conversation.messages[index].text = String(answer[..<end])
                let layoutStart = ContinuousClock.now
                host.layoutSubtreeIfNeeded()
                layoutDurations.append((ContinuousClock.now - layoutStart) / .milliseconds(1))
                try await Task.sleep(for: .milliseconds(50))
            }
            let index = try #require(conversation.messages.firstIndex { $0.id == streamingID })
            conversation.messages[index].isStreaming = false
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .seconds(1))

            let report = stalls.report()
            let sorted = layoutDurations.sorted()
            print("""
            chat streaming benchmark: \(answer.utf8.count) bytes, \(historyCount) earlier answers, \(layoutDurations.count) updates, \
            \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms
            layout per update: median \(Int(sorted[sorted.count / 2])) ms, p95 \(Int(sorted[sorted.count * 95 / 100])) ms, max \(Int(sorted
                    .last ?? 0)) ms
            main thread stalls >= 50 ms: \(report.count), max \(report.max) ms, total \(report.total) ms
            stalls >= 250 ms: \(report.timeline)
            """)
        }
    }

    /// Pings the main queue from a background thread, like `MainActorHangMonitor`, and keeps the stalls in memory.
    private final class StallProbe: @unchecked Sendable {
        // shortcut: lock-protected state shared with one background thread; fine for a benchmark, not for app code.
        private let state = OSAllocatedUnfairLock(initialState: (running: false, stalls: [Int](), offsets: [Int]()))
        private let origin = ContinuousClock.now

        func start() {
            state.withLock { $0.running = true }
            Thread { [self] in
                while state.withLock({ $0.running }) {
                    let sent = ContinuousClock.now
                    let semaphore = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { semaphore.signal() }
                    semaphore.wait()
                    let milliseconds = Int((ContinuousClock.now - sent) / .milliseconds(1))
                    if milliseconds >= 50 {
                        let offset = Int((sent - origin) / .milliseconds(1))
                        state.withLock { $0.stalls.append(milliseconds)
                            $0.offsets.append(offset)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }.start()
        }

        func stop() {
            state.withLock { $0.running = false }
        }

        func report() -> (count: Int, max: Int, total: Int, timeline: String) {
            let (stalls, offsets) = state.withLock { ($0.stalls, $0.offsets) }
            let timeline = zip(offsets, stalls).filter { $0.1 >= 250 }.map { "\($0.1) ms at \($0.0) ms" }.joined(separator: ", ")
            return (stalls.count, stalls.max() ?? 0, stalls.reduce(0, +), timeline)
        }
    }
#endif
