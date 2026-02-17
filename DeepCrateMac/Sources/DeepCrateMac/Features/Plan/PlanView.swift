import SwiftUI

struct PlanView: View {
    private enum FocusTarget: Hashable {
        case name
        case description
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var name: String = "Sunday Session"
    @State private var duration: Int = 60
    @State private var description: String = "60 min liquid DnB set, start mellow, peak at 40 min"
    @State private var isPlanning = false
    @FocusState private var focusedField: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plan Set")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))

                Spacer()

                LiquidStatusBadge(
                    text: settings.plannerMode == .localApple ? "On-device Apple Model" : "Cloud OpenAI Model",
                    symbol: settings.plannerMode == .localApple ? "cpu" : "network"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Planner")
                    .font(.headline)
                HStack {
                    Text("Mode")
                    Picker("Planner", selection: $settings.plannerMode) {
                        ForEach(AppSettings.PlannerMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }

                if settings.plannerMode == .localApple {
                    Text("Uses Apple Foundation Models on-device when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.04)

            VStack(alignment: .leading, spacing: 10) {
                Text("Prompt")
                    .font(.headline)
                TextField("Set Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                Stepper("Duration: \(duration) min", value: $duration, in: 10...360)
                TextEditor(text: $description)
                    .frame(minHeight: 150)
                    .padding(6)
                    .focused($focusedField, equals: .description)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous)
                            .stroke(.quaternary)
                            .allowsHitTesting(false)
                    )
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.04)

            HStack {
                Button {
                    Task { await planSet() }
                } label: {
                    Label(isPlanning ? "Planning..." : "Generate Set", systemImage: "wand.and.stars")
                }
                .disabled(isPlanning || name.isEmpty || description.isEmpty)
                .buttonStyle(.borderedProminent)

                if let latest = appState.setSummaries.first {
                    Text("Latest: \(latest.name)")
                        .foregroundStyle(.secondary)
                }
            }
            .liquidCard(cornerRadius: LiquidMetrics.compactRadius, material: .ultraThinMaterial, contentPadding: 10, shadowOpacity: 0.04)
        }
        .task {
            await refreshSets()
        }
    }

    private func planSet() async {
        isPlanning = true
        appState.statusMessage = "Planning set..."
        defer { isPlanning = false }

        let localDescription = description
        let localName = name
        let localDuration = duration

        if settings.plannerMode == .localApple {
            await planWithAppleModel(description: localDescription, name: localName, duration: localDuration)
            return
        }

        do {
            try await Task.detached {
                try BackendClient().plan(description: localDescription, name: localName, duration: localDuration)
            }.value
            appState.statusMessage = "Created set \(localName)"
            await refreshSets()
        } catch {
            appState.statusMessage = "Planning failed: \(error.localizedDescription)"
        }
    }

    private func planWithAppleModel(description: String, name: String, duration: Int) async {
        do {
            let tracks: [Track]
            if appState.libraryTracks.isEmpty {
                tracks = try await Task.detached {
                    try BackendClient().tracks(query: "", bpm: "", key: "", energy: "")
                }.value
                appState.libraryTracks = tracks
            } else {
                tracks = appState.libraryTracks
            }

            let planner = LocalApplePlanner()
            let ids = try await planner.planTrackIDs(description: description, durationMinutes: duration, tracks: tracks)
            if ids.isEmpty {
                appState.statusMessage = "Apple model returned no tracks."
                return
            }

            try await Task.detached {
                try BackendClient().saveSet(
                    name: name,
                    description: description,
                    duration: duration,
                    trackIDs: ids
                )
            }.value
            appState.statusMessage = "Created set \(name) with local Apple model"
            await refreshSets()
        } catch {
            appState.statusMessage = "Local planning failed: \(error.localizedDescription)"
        }
    }

    private func refreshSets() async {
        do {
            let sets = try await Task.detached {
                try BackendClient().sets()
            }.value
            appState.setSummaries = sets
        } catch {
            appState.statusMessage = "Failed to load sets: \(error.localizedDescription)"
        }
    }
}
