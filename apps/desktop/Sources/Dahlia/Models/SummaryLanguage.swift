/// AI 要約の出力言語。
enum SummaryLanguage: String, CaseIterable, Identifiable {
    case ja
    case en
    case zh
    case ko
    case fr
    case de
    case es

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ja: "日本語"
        case .en: "English"
        case .zh: "中文"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        }
    }
}
