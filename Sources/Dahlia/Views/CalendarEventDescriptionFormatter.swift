import AppKit

@MainActor
enum CalendarEventDescriptionFormatter {
    private static let allowedLinkSchemes = Set(["http", "https", "mailto"])
    private static let supportedHTMLTags = Set([
        "a", "b", "blockquote", "body", "br", "code", "del", "div", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "html", "i", "li", "ol", "p", "pre", "span", "strong", "table", "tbody", "td", "th", "thead", "tr", "u", "ul",
    ])
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedString(
        from description: String,
        baseFontSize: CGFloat = CGFloat(AppSettings.defaultInterfaceFontSize)
    ) -> AttributedString {
        let attributedDescription = NSMutableAttributedString(
            attributedString: source(from: description, baseFontSize: baseFontSize)
        )
        addDetectedLinks(to: attributedDescription)

        var attributed = AttributedString(attributedDescription)
        for run in attributed.runs where !isAllowed(run.link) {
            attributed[run.range].link = nil
        }
        return attributed
    }

    private static func source(from description: String, baseFontSize: CGFloat) -> NSAttributedString {
        guard containsHTML(description),
              let data = styledHTML(description, baseFontSize: baseFontSize).data(using: .utf8),
              let attributedHTML = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              ) else {
            return NSAttributedString(string: description)
        }

        return attributedHTML
    }

    private static func addDetectedLinks(to attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        linkDetector?.enumerateMatches(in: attributed.string, range: fullRange) { result, _, _ in
            guard let result,
                  let url = result.url,
                  isAllowed(url),
                  attributed.attribute(.link, at: result.range.location, effectiveRange: nil) == nil else { return }

            attributed.addAttribute(.link, value: url, range: result.range)
        }
    }

    private static func styledHTML(_ html: String, baseFontSize: CGFloat) -> String {
        "<style>body { font-family: -apple-system; font-size: \(baseFontSize)px; }</style>\(html)"
    }

    private static func containsHTML(_ text: String) -> Bool {
        text.matches(of: #/<\s*\/?\s*([A-Za-z][A-Za-z0-9]*)\b[^>]*>/#)
            .contains { supportedHTMLTags.contains($0.1.lowercased()) }
    }

    private static func isAllowed(_ link: URL?) -> Bool {
        guard let link else { return true }
        guard let scheme = link.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }
}
