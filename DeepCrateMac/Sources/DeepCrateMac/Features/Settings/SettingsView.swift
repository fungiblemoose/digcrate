import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Planner") {
                Picker("Mode", selection: $settings.plannerMode) {
                    ForEach(AppSettings.PlannerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                TextField("OpenAI Model", text: $settings.openAIModel)
            }

            Section("Credentials") {
                SecureField("OpenAI API Key", text: $settings.openAIKey)
                TextField("Spotify Client ID", text: $settings.spotifyClientID)
                SecureField("Spotify Client Secret", text: $settings.spotifyClientSecret)
            }

            Section("Storage") {
                TextField("Database Path", text: $settings.databasePath)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 560)
    }
}
