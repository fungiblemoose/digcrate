import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedSetID: Int?
    @State private var gapNumber: Int = 1
    @State private var genre: String = "drum and bass"
    @State private var limit: Int = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Discover")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            GroupBox("Lookup") {
                HStack {
                    Picker("Set", selection: $selectedSetID) {
                        Text("Select Set").tag(Optional<Int>.none)
                        ForEach(appState.setSummaries) { setPlan in
                            Text(setPlan.name).tag(Optional(setPlan.id))
                        }
                    }
                    .frame(maxWidth: 360)

                    Stepper("Gap #\(gapNumber)", value: $gapNumber, in: 1...20)
                    TextField("Genre", text: $genre)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Limit \(limit)", value: $limit, in: 1...50)
                    Button("Find Suggestions") {
                        Task { await discover() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if appState.discoverResults.isEmpty {
                ContentUnavailableView("No discovery results", systemImage: "magnifyingglass")
            } else {
                Table(appState.discoverResults) {
                    TableColumn("Artist", value: \.artist)
                    TableColumn("Track", value: \.title)
                    TableColumn("BPM") { track in Text("\(Int(track.bpm))") }
                    TableColumn("Energy") { track in Text(String(format: "%.2f", track.energy)) }
                    TableColumn("URL", value: \.url)
                }
                .frame(minHeight: 420)
                .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.05)
            }
        }
        .task {
            await refreshSets()
        }
    }

    private func refreshSets() async {
        do {
            let sets = try await Task.detached {
                try LocalDatabase.shared.listSets()
            }.value
            appState.setSummaries = sets
            if selectedSetID == nil {
                selectedSetID = sets.first?.id
            }
        } catch {
            appState.statusMessage = "Failed to load sets: \(error.localizedDescription)"
        }
    }

    private func discover() async {
        guard let selectedSet = appState.setSummaries.first(where: { $0.id == selectedSetID }) else {
            appState.statusMessage = "Choose a set first"
            return
        }
        let name = selectedSet.name
        let localGap = gapNumber
        let localGenre = genre
        let localLimit = limit

        do {
            let results = try await Task.detached {
                try BackendClient().discover(
                    name: name,
                    gap: localGap,
                    genre: localGenre,
                    limit: localLimit
                )
            }.value
            appState.discoverResults = results
            appState.statusMessage = "Found \(results.count) suggestions"
        } catch {
            appState.statusMessage = "Discover failed: \(error.localizedDescription)"
        }
    }
}
