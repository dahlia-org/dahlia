import SwiftUI

/// How the whole app looks: the display language and sidebar (General), the menu bar calendar (Menu Bar), and which
/// events appear (Event Display). Each account's calendar sources are in `CalendarSettingsView`. The tabs look like the
/// Agents page's.
struct AppearanceSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case menuBar
        case eventDisplay

        var id: Self { self }

        var label: String {
            switch self {
            case .general: L10n.general
            case .menuBar: L10n.appearanceMenuBar
            case .eventDisplay: L10n.appearanceEventDisplay
            }
        }
    }

    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var meetingSidebarRowStyle = MeetingSidebarRowStyle.standard.rawValue
    @AppStorage(DahliaTypography.baseSizeUserDefaultsKey) private var textSize = Int(DahliaTypography.defaultBaseSize)
    @Environment(MainWindowNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            // In a grouped form's header, the tabs share the column of the settings title and the sections below.
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(tabs: Tab.allCases, selection: $navigation.appearanceTab, label: \.label, accessibilityLabel: L10n.appearance)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                switch navigation.appearanceTab {
                case .general: generalSection
                case .menuBar: menuBarCalendarSection
                case .eventDisplay: CalendarEventFilterSettingsView(settings: settings)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
        }
        .onAppear {
            meetingSidebarRowStyle = MeetingSidebarRowStyle.resolved(rawValue: meetingSidebarRowStyle).rawValue
        }
    }

    private var generalSection: some View {
        Section {
            DahliaMenuPicker(
                title: L10n.appearance,
                selection: $settings.appAppearance,
                options: AppAppearance.allCases,
                label: \.displayName
            )
            DahliaMenuPicker(
                title: L10n.appLanguage,
                selection: $settings.appLanguage,
                options: AppLanguage.allCases,
                label: \.displayName
            )
            DahliaMenuPicker(
                title: L10n.textSize,
                description: L10n.textSizeDescription,
                selection: $textSize,
                options: DahliaTypography.baseSizeOptions
            ) { $0 == Int(DahliaTypography.defaultBaseSize) ? L10n.defaultTextSize($0) : L10n.textSizePoints($0) }
            DahliaSegmentedPicker(
                title: L10n.sidebarDisplayStyle,
                selection: $meetingSidebarRowStyle,
                options: MeetingSidebarRowStyle.allCases.map(\.rawValue)
            ) { MeetingSidebarRowStyle.resolved(rawValue: $0).label }
        } footer: {
            Text(L10n.textSizeFooter)
        }
    }

    private var menuBarCalendarSection: some View {
        Section {
            Toggle(isOn: $settings.menuBarCalendarEnabled) {
                Text(L10n.menuBarCalendarDisplay)
                Text(L10n.menuBarCalendarDisplayDescription)
            }
            .toggleStyle(.switch)

            Toggle(isOn: $settings.menuBarCalendarShowsEventTitle) {
                Text(L10n.menuBarCalendarEventTitle)
                Text(L10n.menuBarCalendarEventTitleDescription)
            }
            .toggleStyle(.switch)
            .disabled(!settings.menuBarCalendarEnabled)

            Toggle(isOn: $settings.menuBarCalendarShowsCountdown) {
                Text(L10n.menuBarCalendarCountdown)
                Text(L10n.menuBarCalendarCountdownDescription)
            }
            .toggleStyle(.switch)
            .disabled(!settings.menuBarCalendarEnabled)
        } header: {
            Text(L10n.menuBarCalendar)
                .font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.menuBarCalendarDescription)
        }
    }
}
