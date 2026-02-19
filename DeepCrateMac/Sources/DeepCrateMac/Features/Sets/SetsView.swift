import SwiftUI

struct SetsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSetID: Int?
    @State private var rows: [SetTrackRow] = []
    @State private var selectedRowID: Int?
    @StateObject private var previewPlayer = AudioPreviewPlayer()

    private var selectedSet: SetSummary? {
        appState.setSummaries.first(where: { $0.id == selectedSetID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sets")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            GroupBox("Set Selection") {
                HStack {
                    Picker("Set", selection: $selectedSetID) {
                        Text("Select Set").tag(Optional<Int>.none)
                        ForEach(appState.setSummaries) { setPlan in
                            Text(setPlan.name).tag(Optional(setPlan.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    .onChange(of: selectedSetID) { _, _ in
                        previewPlayer.stopPreview(clearSelection: true)
                        Task { await loadSelectedSetRows() }
                    }

                    Button("Refresh Sets") {
                        Task { await refreshSets() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let setPlan = selectedSet {
                HSplitView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(setPlan.description)
                            .foregroundStyle(.secondary)
                        Table(rows, selection: $selectedRowID) {
                            TableColumn("Preview") { row in
                                Button {
                                    previewPlayer.togglePreview(for: previewTrack(for: row))
                                } label: {
                                    Image(systemName: previewSymbol(for: row))
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                            .width(min: 66, ideal: 72, max: 72)

                            TableColumn("#") { row in Text("\(row.position)") }
                            TableColumn("Artist", value: \.artist)
                            TableColumn("Title", value: \.title)
                            TableColumn("BPM") { row in Text("\(Int(row.bpm))") }
                            TableColumn("Key", value: \.key)
                            TableColumn("Energy") { row in Text(String(format: "%.2f", row.energy)) }
                            TableColumn("Transition", value: \.transition)
                        }
                        .frame(minHeight: 420)
                    }
                    .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.05)

                    transitionInspector
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                        .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .thinMaterial, contentPadding: 14, shadowOpacity: 0.05)
                }
            } else {
                ContentUnavailableView("No set selected", systemImage: "list.number")
            }

            if let error = previewPlayer.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            await refreshSets()
        }
        .onDisappear {
            previewPlayer.stopPreview(clearSelection: true)
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
            await loadSelectedSetRows()
        } catch {
            appState.statusMessage = "Failed to load sets: \(error.localizedDescription)"
        }
    }

    private func loadSelectedSetRows() async {
        guard let selectedSet else { return }
        let name = selectedSet.name
        do {
            let loadedRows = try await Task.detached {
                try LocalDatabase.shared.setTrackRows(name: name)
            }.value
            previewPlayer.stopPreview(clearSelection: true)
            rows = loadedRows
            selectedRowID = loadedRows.first(where: { $0.position > 1 })?.id ?? loadedRows.first?.id
        } catch {
            appState.statusMessage = "Failed to load set tracks: \(error.localizedDescription)"
        }
    }

    private var selectedRow: SetTrackRow? {
        guard let selectedRowID else { return nil }
        return rows.first(where: { $0.id == selectedRowID })
    }

    private var transitionInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transition Breakdown")
                .font(.headline)

            if let row = selectedRow {
                Text(row.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Button {
                        previewPlayer.togglePreview(for: previewTrack(for: row))
                    } label: {
                        Label(previewButtonTitle(for: row), systemImage: previewSymbol(for: row))
                    }
                    .buttonStyle(.bordered)

                    if let previous = previousRow(for: row) {
                        Text("From: \(previous.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Opening track")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isPreviewing(row) {
                    Slider(
                        value: Binding(
                            get: { previewPlayer.progress },
                            set: { previewPlayer.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)

                    HStack {
                        Text(formatTimecode(previewPlayer.currentTime))
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text(formatTimecode(previewPlayer.previewDuration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let previous = previousRow(for: row) {
                    HStack(spacing: 10) {
                        StatChip(title: "Rating", value: row.transition)
                        StatChip(title: "BPM Δ", value: "\(Int(abs(row.bpm - previous.bpm).rounded()))")
                        StatChip(title: "Energy Δ", value: energyDeltaText(from: previous, to: row))
                    }

                    Text(transitionExplanation(for: row, previous: previous))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Smart Notes")
                        .font(.subheadline.weight(.semibold))
                    Text("This explanation is generated from BPM, Camelot key relationship, and energy movement for quick DJ decisions.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("This is the opening track, so there is no incoming transition to rate.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a track row to inspect why its transition rating is high or low.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func previousRow(for row: SetTrackRow) -> SetTrackRow? {
        rows.first(where: { $0.position == row.position - 1 })
    }

    private func transitionExplanation(for row: SetTrackRow, previous: SetTrackRow) -> String {
        let bpmDelta = abs(row.bpm - previous.bpm)
        let bpmText: String
        if bpmDelta <= 2 {
            bpmText = "BPM is tightly matched"
        } else if bpmDelta <= 6 {
            bpmText = "BPM change is manageable"
        } else {
            bpmText = "BPM jump is large"
        }

        let keyText = keyRelationship(from: previous.key, to: row.key)
        let energyDelta = row.energy - previous.energy
        let energyText: String
        if abs(energyDelta) <= 0.08 {
            energyText = "energy stays level"
        } else if energyDelta > 0 {
            energyText = "energy lifts into the next track"
        } else {
            energyText = "energy drops into a calmer section"
        }

        return "\(bpmText). \(keyText). \(energyText)."
    }

    private func energyDeltaText(from previous: SetTrackRow, to current: SetTrackRow) -> String {
        let delta = current.energy - previous.energy
        return String(format: "%+.2f", delta)
    }

    private func keyRelationship(from source: String, to destination: String) -> String {
        guard let start = parseCamelot(source), let end = parseCamelot(destination) else {
            return "Key relation is unknown"
        }
        if start.number == end.number && start.letter == end.letter {
            return "Same Camelot key"
        }
        if start.number == end.number && start.letter != end.letter {
            return "Relative major/minor pair"
        }
        if start.letter == end.letter {
            let distance = min(abs(start.number - end.number), 12 - abs(start.number - end.number))
            if distance == 1 {
                return "Adjacent harmonic keys"
            }
            if distance == 2 {
                return "Two-step key move"
            }
        }
        return "Weak harmonic match"
    }

    private func parseCamelot(_ value: String) -> (number: Int, letter: Character)? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let letter = normalized.last, letter == "A" || letter == "B" else { return nil }
        guard let number = Int(normalized.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }

    private func previewTrack(for row: SetTrackRow) -> Track {
        Track(
            id: row.id,
            artist: row.artist,
            title: row.title,
            bpm: row.bpm,
            key: row.key,
            energy: row.energy,
            duration: 0,
            filePath: row.filePath,
            previewStart: row.previewStart
        )
    }

    private func isPreviewing(_ row: SetTrackRow) -> Bool {
        previewPlayer.activeTrackID == row.id && previewPlayer.isPlaying
    }

    private func previewSymbol(for row: SetTrackRow) -> String {
        isPreviewing(row) ? "stop.fill" : "play.fill"
    }

    private func previewButtonTitle(for row: SetTrackRow) -> String {
        isPreviewing(row) ? "Stop Preview" : "Play Preview"
    }
}

private struct StatChip: View {
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

private extension SetTrackRow {
    var displayName: String {
        "\(artist) - \(title)"
    }
}
