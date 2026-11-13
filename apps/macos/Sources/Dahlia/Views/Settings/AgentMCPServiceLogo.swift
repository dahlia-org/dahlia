import SwiftUI

enum AgentMCPServiceLogo {
    /// The service's brand logo by keyword; services with no brand of their own show a symbol.
    static func image(for service: String) -> Image {
        let name = service.lowercased()
        let logos = [
            ("slack", "IntegrationSlack"), ("gmail", "IntegrationGmail"), ("drive", "IntegrationGoogleDrive"),
            ("github", "IntegrationGitHub"), ("atlassian", "IntegrationAtlassian"), ("jira", "IntegrationAtlassian"),
            ("confluence", "IntegrationAtlassian"), ("calendar", "IntegrationGoogleCalendar"),
            ("microsoft", "IntegrationMicrosoft365"), ("genie", "IntegrationGenie"), ("sql", "IntegrationDBSQL"),
        ]
        if let logo = logos.first(where: { name.contains($0.0) }), let image = Bundle.appModule.image(forResource: logo.1) {
            // The GitHub mark is black, so it takes the text color to show in dark mode.
            return Image(nsImage: image).renderingMode(logo.1 == "IntegrationGitHub" ? .template : .original)
        }
        if name.contains("search") { return Image(systemName: "magnifyingglass") }
        if name.contains("sandbox") { return Image(systemName: "apple.terminal") }
        return Image(systemName: "puzzlepiece.extension")
    }
}
