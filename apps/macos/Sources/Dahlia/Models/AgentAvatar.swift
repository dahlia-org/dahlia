import AppKit

/// An agent's picture: one of the bundled mascots (Orca's, MIT; see `AgentMascots-LICENSE.txt`) on a tile of its color.
enum AgentAvatar {
    /// The bundled mascots, `AgentMascot<id>.webp` in the resources.
    static let mascots = [
        "A1", "B1", "D1", "E1", "F1", "G1", "H1", "H2", "I1", "J1", "K2", "L2", "M1", "N1", "O1", "P3", "Q1", "R3", "S2", "T1",
    ]
    /// The mascots' own sky blue.
    static let defaultColor = "#b3dbf4"
    /// The picker's swatches, the default first. A dark tile would need a rimmed picture, so there is none.
    static let colors = [defaultColor, "#ffffff", "#c9b8e8", "#f4c4cf", "#f8cfa8", "#f6e3a1", "#c5dfb5", "#b5e3d8", "#8fa3b8"]

    static func mascot(_ id: String) -> String { "mascot:" + id }

    static func random() -> String { mascot(mascots.randomElement()!) }

    /// The mascot an avatar names, or the first one for a value this build does not know.
    static func mascotID(_ avatar: String) -> String {
        let id = String(avatar.dropFirst("mascot:".count))
        return avatar.hasPrefix("mascot:") && mascots.contains(id) ? id : mascots[0]
    }

    static func isValid(avatar: String, color: String) -> Bool {
        avatar.hasPrefix("mascot:") && mascots.contains(String(avatar.dropFirst("mascot:".count)))
            && color.wholeMatch(of: /#[0-9a-f]{6}/) != nil
    }

    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor static func image(_ avatar: String) -> NSImage? {
        let id = mascotID(avatar)
        if let image = images[id] { return image }
        let image = Bundle.appModule.url(forResource: "AgentMascot" + id, withExtension: "webp").flatMap(NSImage.init(contentsOf:))
        images[id] = image
        return image
    }
}
