import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation

extension ObsidianMarkdownSummaryRenderer {
    /// アプリ側の `SummaryRenderContext` から共有レンダラーを呼ぶ。
    /// 描画そのものは `DahliaRuntimeSupport` にあり、MCP ヘルパーと同じ出力になる。
    static func render(document: SummaryDocument, context: SummaryRenderContext) -> SummaryMarkdownRenderResult {
        var screenshotURLs: [UUID: URL] = [:]
        for screenshot in context.screenshots where screenshotURLs[screenshot.id] == nil {
            screenshotURLs[screenshot.id] = (screenshot.localReference ?? screenshot.remoteReference)
                .flatMap(ScreenshotFileStore.originalFileURL(reference:))
        }

        return render(
            document: document,
            context: SummaryMarkdownRenderContext(
                meetingId: context.meetingId,
                createdAt: context.createdAt,
                screenshotURLs: screenshotURLs
            ),
            actionItemsHeading: L10n.actionItems
        )
    }
}
