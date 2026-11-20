import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatMarkdownTextViewTests {
        @Test
        func firstMeasurementIsExactWithoutWaiting() throws {
            let reference = try #require(Self.makeTextView().measuredHeight(constrainedTo: 400))
            let textView = Self.makeTextView()

            #expect(reference > 0)
            #expect(textView.measuredHeight(constrainedTo: 400) == reference)
        }

        @Test
        func widthChangeReturnsAnAreaPreservingEstimate() throws {
            let textView = Self.makeTextView()
            let wideHeight = try #require(textView.measuredHeight(constrainedTo: 400))

            let estimate = try #require(textView.measuredHeight(constrainedTo: 200))

            // 同期レイアウトをやり直さず、幅の比で高さを見積もって即座に返す。
            #expect(estimate == (wideHeight * 400 / 200).rounded(.up))
        }

        @Test
        func widthChangeConvergesToTheExactHeight() async throws {
            let exact = try #require(Self.makeTextView().measuredHeight(constrainedTo: 200))
            let textView = Self.makeTextView()
            _ = textView.measuredHeight(constrainedTo: 400)
            // SwiftUI applies the final width through the frame after asking for sizes.
            textView.setFrameSize(NSSize(width: 200, height: 0))

            let settled = try await Self.settledHeight(of: textView, width: 200, expecting: exact)

            #expect(settled == exact)
        }

        @Test
        func burstOfWidthChangesConvergesToTheFinalWidth() async throws {
            let exact = try #require(Self.makeTextView().measuredHeight(constrainedTo: 240))
            let textView = Self.makeTextView()

            // リサイズドラッグのように 1 フレーム未満の間隔で幅が変わり続ける状況。
            let widths: [CGFloat] = [400, 360, 320, 280, 240]
            _ = textView.measuredHeight(constrainedTo: widths[0])
            for width in widths {
                textView.setFrameSize(NSSize(width: width, height: 0))
            }

            let settled = try await Self.settledHeight(of: textView, width: 240, expecting: exact)

            #expect(settled == exact)
        }

        @Test
        func probeWidthsLeaveTheLayoutAtTheViewWidth() throws {
            let textView = Self.makeTextView()
            let exact = try #require(textView.measuredHeight(constrainedTo: 400))

            // SwiftUI asks at other widths during one layout pass; those must not discard the layout.
            for probe: CGFloat in [0, 32, 167.5, 688] {
                _ = textView.measuredHeight(constrainedTo: probe)
            }

            #expect(textView.measuredHeight(constrainedTo: 400) == exact)
            #expect(textView.measuredHeight(constrainedTo: 200) == (exact * 400 / 200).rounded(.up))
        }

        @Test
        func largeCodeBlockPreservesAllSelectableText() throws {
            let text = String(repeating: "summary line\n", count: 400)
            let textView = CodexChatSelectableTextView.makeConfigured()
            textView.setBlocks([.code(language: "json", text: text)])

            #expect(text.utf8.count > 4096)
            #expect(textView.attributedString().string == text)
            #expect(try #require(textView.measuredHeight(constrainedTo: 400)) > 0)
        }

        private static func makeTextView() -> CodexChatSelectableTextView {
            let textView = CodexChatSelectableTextView.makeConfigured()
            let blocks = (0 ..< 20).map { index in
                CodexChatMarkdownRenderedBlock.paragraph(AttributedString(
                    "Paragraph \(index): " + String(repeating: "measurement sample text ", count: 5)
                ))
            }
            textView.setBlocks(blocks)
            return textView
        }

        private static func settledHeight(
            of textView: CodexChatSelectableTextView,
            width: CGFloat,
            expecting expected: CGFloat
        ) async throws -> CGFloat {
            for _ in 0 ..< 200 {
                let height = try #require(textView.measuredHeight(constrainedTo: width))
                if height == expected {
                    return height
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            return try #require(textView.measuredHeight(constrainedTo: width))
        }
    }
#endif
