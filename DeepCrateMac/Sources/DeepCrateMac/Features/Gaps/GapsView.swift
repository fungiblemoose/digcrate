import SwiftUI

struct GapsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSetID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gap Analysis")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            GroupBox("Analyze") {
                HStack {
                    Picker("Set", selection: $selectedSetID) {
                        Text("Select Set").tag(Optional<Int>.none)
                        ForEach(appState.setSummaries) { setPlan in
                            Text(setPlan.name).tag(Optional(setPlan.id))
                        }
                    }
                    .frame(maxWidth: 360)

                    Button("Analyze Current Set") {
                        Task { await analyze() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if appState.gapSuggestions.isEmpty {
                ContentUnavailableView("No gaps yet", systemImage: "link.badge.plus")
            } else {
                Table(appState.gapSuggestions) {
                    TableColumn("From", value: \.fromTrack)
                    TableColumn("To", value: \.toTrack)
                    TableColumn("Score") { gap in Text("\(Int(gap.score * 100))%") }
                    TableColumn("Need BPM") { gap in Text("\(Int(gap.suggestedBPM))") }
                    TableColumn("Need Key", value: \.suggestedKey)
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
                try BackendClient().sets()
            }.value
            appState.setSummaries = sets
            if selectedSetID == nil {
                selectedSetID = sets.first?.id
            }
        } catch {
            appState.statusMessage = "Failed to load sets: \(error.localizedDescription)"
        }
    }

    private func analyze() async {
        guard let selectedSet = appState.setSummaries.first(where: { $0.id == selectedSetID }) else {
            appState.statusMessage = "No set available"
            return
        }
        let name = selectedSet.name

        do {
            let gaps = try await Task.detached {
                try BackendClient().gaps(name: name)
            }.value
            appState.gapSuggestions = gaps
            appState.statusMessage = gaps.isEmpty ? "No major gaps found" : "Found \(gaps.count) gaps"
        } catch {
            appState.statusMessage = "Gap analysis failed: \(error.localizedDescription)"
        }
    }
}
