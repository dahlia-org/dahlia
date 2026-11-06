import AppKit
import SwiftUI

extension NSImage {
    /// The bundled Databricks logo, marking Databricks accounts and sign-in.
    static var databricksLogo: NSImage {
        Bundle.appModule.url(forResource: "ProviderDatabricks", withExtension: "svg").flatMap(Self.init(contentsOf:))
            ?? Self(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? Self()
    }
}

extension Image {
    static var databricksLogo: Image { Image(nsImage: .databricksLogo) }
}
