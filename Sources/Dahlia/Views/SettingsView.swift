import AppKit
import SwiftUI

/// 設定画面のカテゴリ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case calendar
    case cloudStorage
    case transcription
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
        case .aiSummary: L10n.aiSummary
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
        case .aiSummary: "sparkle.text.clipboard"
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

/// 設定画面（Cmd+, で表示）。サイドバーでセクションを切り替える。
struct SettingsView: View {
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @AppStorage(SettingsNavigation.selectedCategoryDefaultsKey)
    private var selectionRawValue = SettingsCategory.general.rawValue

    private let sidebarWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(SettingsCategory.allCases) { category in
                        settingsSidebarRow(for: category)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 18)

                Spacer(minLength: 0)
            }
            .frame(width: sidebarWidth)
            .background(.bar)

            Divider()

            selectedCategoryView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder
    private var selectedCategoryView: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsView(sidebarViewModel: sidebarViewModel, onSelectVault: onSelectVault)
        case .calendar:
            CalendarSettingsView()
        case .cloudStorage:
            CloudStorageSettingsView()
        case .transcription:
            TranscriptionSettingsView()
        case .aiSummary:
            AISummarySettingsView()
        case .instructions:
            InstructionsSettingsView(sidebarViewModel: sidebarViewModel)
        case .developer:
            DeveloperSettingsView()
        }
    }

    private func settingsSidebarRow(for category: SettingsCategory) -> some View {
        Button {
            selectionRawValue = category.rawValue
        } label: {
            Label(category.label, systemImage: category.systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selectedCategory == category ? Color.primary.opacity(0.08) : Color.clear)
        )
    }

    private var selectedCategory: SettingsCategory {
        SettingsCategory(rawValue: selectionRawValue) ?? .general
    }
}
