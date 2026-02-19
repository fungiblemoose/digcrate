import SwiftUI

struct GapsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSetID: Int?
    @State private var selectedGapID: GapSuggestion.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gap Analysis")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("What This Page Does")
                    .font(.headline)
                Text("Gap Analysis finds weak transitions in your set and suggests target BPM/key for a bridge track.")
                    .foregroundStyle(.secondary)
                Text("Match % is transition quality (0-100). Lower means weaker and usually needs a filler track.")
                    .foregroundStyle(.secondary)
                Text("Use Bridge BPM + Bridge Key to search for a track that sits naturally between the two songs.")
                    .foregroundStyle(.secondary)
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.04)

            GroupBox("Analyze") {
                HStack(alignment: .center) {
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

                    Text("Run this after you generate or edit a set.")
                        .foregroundStyle(.secondary)
                }
            }

            if appState.gapSuggestions.isEmpty {
                ContentUnavailableView(
                    "No gaps yet",
                    systemImage: "link.badge.plus",
                    description: Text("Pick a set above and run Analyze Current Set.")
                )
            } else {
                HSplitView {
                    Table(appState.gapSuggestions, selection: $selectedGapID) {
                        TableColumn("From", value: \.fromTrack)
                        TableColumn("To", value: \.toTrack)
                        TableColumn("Match") { gap in Text("\(Int((gap.score * 100).rounded()))%") }
                        TableColumn("Severity") { gap in
                            Text(severityLabel(for: gap.score))
                                .foregroundStyle(severityColor(for: gap.score))
                        }
                        TableColumn("Bridge BPM") { gap in Text("\(Int(gap.suggestedBPM.rounded()))") }
                        TableColumn("Bridge Key", value: \.suggestedKey)
                    }
                    .frame(minHeight: 420)

                    gapInspector
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                        .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .thinMaterial, contentPadding: 14, shadowOpacity: 0.05)
                }
                .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.05)
            }
        }
        .task {
            await refreshSets()
        }
        .onChange(of: appState.gapSuggestions) { _, newValue in
            if selectedGapID == nil {
                selectedGapID = newValue.first?.id
            }
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

    private func analyze() async {
        guard let selectedSet = appState.setSummaries.first(where: { $0.id == selectedSetID }) else {
            appState.statusMessage = "No set available"
            return
        }
        let name = selectedSet.name

        do {
            let gaps = try await Task.detached {
                try LocalDatabase.shared.analyzeGaps(name: name)
            }.value
            appState.gapSuggestions = gaps
            selectedGapID = gaps.first?.id
            appState.statusMessage = gaps.isEmpty ? "No major gaps found" : "Found \(gaps.count) gaps"
        } catch {
            appState.statusMessage = "Gap analysis failed: \(error.localizedDescription)"
        }
    }

    private var selectedGap: GapSuggestion? {
        guard let selectedGapID else { return nil }
        return appState.gapSuggestions.first(where: { $0.id == selectedGapID })
    }

    private var gapInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How To Fix This Gap")
                .font(.headline)

            if let gap = selectedGap {
                Text("\(gap.fromTrack) -> \(gap.toTrack)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    GapStatChip(title: "Match", value: "\(Int((gap.score * 100).rounded()))%")
                    GapStatChip(title: "Severity", value: severityLabel(for: gap.score))
                    GapStatChip(title: "Bridge", value: "\(Int(gap.suggestedBPM.rounded())) BPM \(gap.suggestedKey)")
                }

                Text(matchExplanation(for: gap.score))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Suggested move: find a track near \(Int(gap.suggestedBPM.rounded())) BPM in \(gap.suggestedKey), then insert it between these tracks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select a gap row to see why it was flagged and how to fix it.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func severityLabel(for score: Double) -> String {
        if score < 0.25 {
            return "Critical"
        }
        if score < 0.35 {
            return "High"
        }
        if score < 0.45 {
            return "Medium"
        }
        return "Low"
    }

    private func severityColor(for score: Double) -> Color {
        if score < 0.25 {
            return .red
        }
        if score < 0.35 {
            return .orange
        }
        if score < 0.45 {
            return .yellow
        }
        return .secondary
    }

    private func matchExplanation(for score: Double) -> String {
        if score < 0.25 {
            return "Very weak transition. BPM, key, or energy likely clash hard. Use a clear bridge track."
        }
        if score < 0.35 {
            return "Weak transition. A bridge track will usually improve blend quality and flow."
        }
        if score < 0.45 {
            return "Slightly weak transition. You might make it work live, but a bridge is safer."
        }
        return "Borderline weak transition. Consider a bridge only if this moment feels abrupt in your test mix."
    }
}

private struct GapStatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous))
    }
}
