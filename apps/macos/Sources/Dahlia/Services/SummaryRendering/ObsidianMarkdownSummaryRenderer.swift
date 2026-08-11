import DahliaRuntimeSupport
import Foundation

extension ObsidianMarkdownSummaryRenderer {
    /// アプリ側の `SummaryRenderContext` から共有レンダラーを呼ぶ。
    /// 描画そのものは `DahliaRuntimeSupport` にあり、MCP ヘルパーと同じ出力になる。
    static func render(document: SummaryDocument, context: SummaryRenderContext) -> SummaryMarkdownRenderResult {
        var screenshotFilenames: [UUID: String] = [:]
        for screenshot in context.screenshots where screenshotFilenames[screenshot.id] == nil {
            screenshotFilenames[screenshot.id] = ScreenshotExportService.filename(for: screenshot)
        }

        return render(
            document: document,
            context: SummaryMarkdownRenderContext(
                meetingId: context.meetingId,
                createdAt: context.createdAt,
                screenshotFilenames: screenshotFilenames
            ),
            actionItemsHeading: L10n.actionItems
        )
    }
}
