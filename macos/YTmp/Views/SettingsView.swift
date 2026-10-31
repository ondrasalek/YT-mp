import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.strings
        @Bindable var app = app
        Form {
            Picker(t("theme"), selection: $app.theme) {
                Text(t("themeSystem")).tag(ThemePreference.system)
                Text(t("themeLight")).tag(ThemePreference.light)
                Text(t("themeDark")).tag(ThemePreference.dark)
            }
            Picker(t("fontsize"), selection: $app.fontSize) {
                Text(t("fsSmall")).tag(FontSizePreference.small)
                Text(t("fsMedium")).tag(FontSizePreference.medium)
                Text(t("fsLarge")).tag(FontSizePreference.large)
            }
            Picker(t("language"), selection: $app.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Section {
                Text(t("disclaimer")).font(.caption).foregroundStyle(.secondary)
                Link(t("terms"), destination: URL(string: "https://www.youtube.com/t/terms")!).font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(app.theme.colorScheme)
        .navigationTitle(t("settingsTitle"))
    }
}
