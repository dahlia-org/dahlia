import AppKit
import SwiftUI

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case calendar
    case cloudStorage
    case transcription
    case screenshots
    case aiSummary
    case instructions
    case developer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: L10n.general
        case .calendar: L10n.calendar
        case .cloudStorage: L10n.cloudStorage
        case .transcription: L10n.transcription
        case .screenshots: L10n.screenshots
        case .aiSummary: L10n.foundationModels
        case .instructions: L10n.instructions
        case .developer: L10n.developerSettings
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .calendar: "calendar"
        case .cloudStorage: "externaldrive.badge.icloud"
        case .transcription: "waveform"
        case .screenshots: "photo.on.rectangle.angled"
        case .aiSummary: "sparkles"
        case .instructions: "list.bullet.clipboard"
        case .developer: "wrench.and.screwdriver"
        }
    }
}

enum SettingsNavigation {
    static let selectedCategoryDefaultsKey = "settingsSelectedCategory"

    @MainActor
    static func open(_ category: SettingsCategory) {
        UserDefaults.standard.set(category.rawValue, forKey: selectedCategoryDefaultsKey)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// 設定画面（Cmd+, で表示）。
struct SettingsView: View {
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @AppStorage(SettingsNavigation.selectedCategoryDefaultsKey)
    private var selection: SettingsCategory = .general

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                SettingsCategory.general.label,
                systemImage: SettingsCategory.general.systemImage,
                value: SettingsCategory.general
            ) {
                GeneralSettingsView(sidebarViewModel: sidebarViewModel, onSelectVault: onSelectVault)
            }

            Tab(
                SettingsCategory.calendar.label,
                systemImage: SettingsCategory.calendar.systemImage,
                value: SettingsCategory.calendar
            ) {
                CalendarSettingsView()
            }

            Tab(
                SettingsCategory.cloudStorage.label,
                systemImage: SettingsCategory.cloudStorage.systemImage,
                value: SettingsCategory.cloudStorage
            ) {
                CloudStorageSettingsView()
            }

            Tab(
                SettingsCategory.transcription.label,
                systemImage: SettingsCategory.transcription.systemImage,
                value: SettingsCategory.transcription
            ) {
                TranscriptionSettingsView()
            }

            Tab(
                SettingsCategory.screenshots.label,
                systemImage: SettingsCategory.screenshots.systemImage,
                value: SettingsCategory.screenshots
            ) {
                ScreenshotSettingsView()
            }

            Tab(
                SettingsCategory.aiSummary.label,
                systemImage: SettingsCategory.aiSummary.systemImage,
                value: SettingsCategory.aiSummary
            ) {
                AISummarySettingsView()
            }

            Tab(
                SettingsCategory.instructions.label,
                systemImage: SettingsCategory.instructions.systemImage,
                value: SettingsCategory.instructions
            ) {
                InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
            }

            Tab(
                SettingsCategory.developer.label,
                systemImage: SettingsCategory.developer.systemImage,
                value: SettingsCategory.developer
            ) {
                DeveloperSettingsView()
            }
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}
