import AppKit
import SwiftUI

private enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "All Tracks"
    case reviewQueue = "Review Queue"

    var id: String { rawValue }
}

private struct AnalysisStatusSnapshot {
    var action: String = "Ready"
    var detail: String = "Choose a folder and start a scan."
    var current: Int = 0
    var total: Int = 0
    var isRunning: Bool = false
    var isIndeterminate: Bool = false
    var isError: Bool = false
}

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState

    @State private var query: String = ""
    @State private var bpmRange: String = ""
    @State private var key: String = ""
    @State private var energyRange: String = ""
    @State private var reviewFilter: ReviewFilter = .all

    @State private var isBusy = false
    @State private var selectedTrackIDs: Set<Int> = []
    @StateObject private var previewPlayer = AudioPreviewPlayer()
    @State private var overrideBPM: String = ""
    @State private var overrideKey: String = ""
    @State private var overrideEnergy: String = ""
    @State private var analysisStatus = AnalysisStatusSnapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statsStrip
            controls
            analysisStatusPanel
            libraryContent

            if let error = previewPlayer.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            await loadTracks()
        }
        .onChange(of: selectedTrackIDs) { _, _ in
            syncOverrideDrafts()
        }
        .onDisappear {
            previewPlayer.stopPreview(clearSelection: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            Text("Preview quickly, fix weird metadata, and move fast when building party crates.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 12) {
            StatPill(title: "Tracks", value: "\(appState.libraryTracks.count)")
            StatPill(title: "Review", value: "\(reviewQueueCount)")
            StatPill(title: "Avg BPM", value: avgBPM)
            StatPill(title: "Avg Energy", value: avgEnergy)
            StatPill(title: "Selected", value: selectedSummaryText)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    pickFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }

                Button {
                    Task { await scan() }
                } label: {
                    Label("Scan", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(isBusy || appState.scannedFolder.isEmpty)

                Button {
                    Task { await reanalyzeSelectedTracks() }
                } label: {
                    Label(
                        selectionCount > 1 ? "Reanalyze Selected (\(selectionCount))" : "Reanalyze Selected",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isBusy || selectionCount == 0)

                Button(role: .destructive) {
                    Task { await deleteSelectedTracks() }
                } label: {
                    Label(
                        selectionCount > 1 ? "Delete Selected (\(selectionCount))" : "Delete Selected",
                        systemImage: "trash"
                    )
                }
                .disabled(isBusy || selectionCount == 0)

                Button {
                    Task { await reanalyzeAllImportedTracks() }
                } label: {
                    Label("Reanalyze All Imported", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .disabled(isBusy)

                Picker("Scope", selection: $reviewFilter) {
                    ForEach(ReviewFilter.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: reviewFilter) { _, _ in
                    Task { await loadTracks() }
                }

                Spacer(minLength: 8)

                Text(appState.scannedFolder.isEmpty ? "No folder selected" : appState.scannedFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                TextField("Search artist or title", text: $query)
                TextField("BPM (e.g. 120-126)", text: $bpmRange)
                    .frame(maxWidth: 150)
                TextField("Key (e.g. 8A)", text: $key)
                    .frame(maxWidth: 110)
                TextField("Energy (e.g. 0.45-0.70)", text: $energyRange)
                    .frame(maxWidth: 170)

                Button {
                    Task { await loadTracks() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(isBusy)

                Button("Select Visible") {
                    selectedTrackIDs = Set(appState.libraryTracks.map(\.id))
                }
                .disabled(appState.libraryTracks.isEmpty || isBusy)

                Button("Clear Selection") {
                    selectedTrackIDs.removeAll()
                    previewPlayer.stopPreview(clearSelection: true)
                }
                .disabled(selectionCount == 0 || isBusy)
            }
            .textFieldStyle(.roundedBorder)
        }
        .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .thinMaterial, contentPadding: 14, shadowOpacity: 0.05)
    }

    private var analysisStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: analysisStatusIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(analysisStatus.isError ? .orange : .primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(analysisStatus.action)
                        .font(.headline)
                    Text(analysisStatus.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if analysisStatus.isRunning {
                    Text(analysisStatus.isIndeterminate ? "Running" : "\(analysisStatus.current)/\(max(analysisStatus.total, 1))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if analysisStatus.isRunning {
                if analysisStatus.isIndeterminate {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    ProgressView(value: Double(analysisStatus.current), total: Double(max(analysisStatus.total, 1)))
                        .controlSize(.regular)
                }
            }
        }
        .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .regularMaterial, contentPadding: 14, shadowOpacity: 0.04)
    }

    private var libraryContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tracks")
                        .font(.headline)
                    Spacer()
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Table(appState.libraryTracks, selection: $selectedTrackIDs) {
                    TableColumn("Preview") { track in
                        Button {
                            previewPlayer.togglePreview(for: track)
                        } label: {
                            Image(systemName: previewSymbol(for: track))
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                    .width(min: 66, ideal: 72, max: 72)

                    TableColumn("Review") { track in
                        if track.needsReview {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green.opacity(0.7))
                        }
                    }
                    .width(min: 56, ideal: 62, max: 66)

                    TableColumn("Artist", value: \.artist)
                    TableColumn("Title", value: \.title)
                    TableColumn("BPM") { track in
                        Text(track.bpm > 0 ? "\(Int(track.bpm.rounded()))" : "-")
                            .monospacedDigit()
                    }
                    .width(min: 56, ideal: 70, max: 80)

                    TableColumn("Key", value: \.key)
                        .width(min: 50, ideal: 55, max: 60)

                    TableColumn("Energy") { track in
                        Text(String(format: "%.2f", track.energy))
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 74, max: 80)

                    TableColumn("Conf") { track in
                        Text(String(format: "%.2f", track.energyConfidence))
                            .monospacedDigit()
                    }
                    .width(min: 68, ideal: 74, max: 80)
                }
                .frame(minHeight: 420)
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.05)

            trackInspector
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .thinMaterial, contentPadding: 14, shadowOpacity: 0.05)
        }
        .padding(2)
    }

    private var trackInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Inspecting")
                .font(.headline)

            if selectionCount > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(selectionCount) tracks selected")
                        .font(.title3.weight(.semibold))
                    Text("Bulk actions are available for reanalysis. Manual overrides apply to single-track selection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await reanalyzeSelectedTracks() }
                        } label: {
                            Label("Reanalyze Selected", systemImage: "arrow.clockwise")
                        }
                        .disabled(isBusy)

                        Button("Clear Selection") {
                            selectedTrackIDs.removeAll()
                            previewPlayer.stopPreview(clearSelection: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }
                }
            } else if let track = selectedTrack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(track.artist.isEmpty ? "Unknown Artist" : track.artist)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    StatPill(title: "BPM", value: track.bpm > 0 ? "\(Int(track.bpm.rounded()))" : "-")
                    StatPill(title: "Key", value: track.key.isEmpty ? "-" : track.key)
                    StatPill(title: "Energy", value: String(format: "%.2f", track.energy))
                    StatPill(title: "Conf", value: String(format: "%.2f", track.energyConfidence))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            previewPlayer.togglePreview(for: track)
                        } label: {
                            Label(previewButtonTitle(for: track), systemImage: previewSymbol(for: track))
                        }

                        Button {
                            Task { await reanalyzeSelectedTracks() }
                        } label: {
                            Label("Reanalyze", systemImage: "arrow.clockwise")
                        }
                        .disabled(isBusy)

                        Button(role: .destructive) {
                            Task { await deleteSelectedTracks() }
                        } label: {
                            Label("Delete from Library", systemImage: "trash")
                        }
                        .disabled(isBusy)
                    }

                    Slider(
                        value: Binding(
                            get: { previewPlayer.progress },
                            set: { previewPlayer.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    .disabled(previewPlayer.activeTrackID != track.id)

                    HStack {
                        Text(formatTimecode(previewPlayer.currentTime))
                            .monospacedDigit()
                        Spacer()
                        Text(formatTimecode(previewPlayer.previewDuration))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if track.needsReview {
                    Label(track.reviewNotes.isEmpty ? "Track flagged for review" : track.reviewNotes, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label("Analysis checks passed", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.8))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration: \(formatTimecode(track.duration))")
                    Text("File: \(track.filePath.isEmpty ? "Unknown" : URL(fileURLWithPath: track.filePath).lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !track.filePath.isEmpty {
                        Text(track.filePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .font(.footnote)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual Corrections")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 8) {
                        TextField("BPM override", text: $overrideBPM)
                        TextField("Key override", text: $overrideKey)
                        TextField("Energy override", text: $overrideEnergy)
                    }
                    .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button {
                            Task { await saveOverrides() }
                        } label: {
                            Label("Save Corrections", systemImage: "checkmark.circle")
                        }
                        .disabled(isBusy)

                        Button {
                            Task { await clearOverrides() }
                        } label: {
                            Label("Clear Corrections", systemImage: "xmark.circle")
                        }
                        .disabled(isBusy || !track.hasOverrides)

                        if track.hasOverrides {
                            Label("Overrides active", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a track to preview and reanalyze.")
                        .foregroundStyle(.secondary)
                    Text("Tip: use preview to validate key/BPM before building a fast party set.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    private var avgBPM: String {
        let valid = appState.libraryTracks.map(\.bpm).filter { $0 > 0 }
        guard !valid.isEmpty else { return "-" }
        let mean = valid.reduce(0, +) / Double(valid.count)
        return "\(Int(mean.rounded()))"
    }

    private var avgEnergy: String {
        let valid = appState.libraryTracks.map(\.energy).filter { $0 > 0 }
        guard !valid.isEmpty else { return "-" }
        return String(format: "%.2f", valid.reduce(0, +) / Double(valid.count))
    }

    private var reviewQueueCount: Int {
        appState.libraryTracks.filter(\.needsReview).count
    }

    private var selectionCount: Int {
        selectedTrackIDs.count
    }

    private var primarySelectedTrackID: Int? {
        selectedTrackIDs.sorted().first
    }

    private var selectedSummaryText: String {
        if let track = selectedTrack {
            return track.title
        }
        if selectionCount > 1 {
            return "\(selectionCount) Tracks"
        }
        return "None"
    }

    private var analysisStatusIcon: String {
        if analysisStatus.isError {
            return "exclamationmark.triangle.fill"
        }
        if analysisStatus.isRunning {
            return "waveform.path.ecg"
        }
        return "checkmark.seal.fill"
    }

    private var selectedTrack: Track? {
        guard selectionCount == 1, let primarySelectedTrackID else { return nil }
        return appState.libraryTracks.first(where: { $0.id == primarySelectedTrackID })
    }

    private func syncOverrideDrafts() {
        guard let selectedTrack else {
            overrideBPM = ""
            overrideKey = ""
            overrideEnergy = ""
            return
        }

        overrideBPM = ""
        overrideKey = ""
        overrideEnergy = ""

        if selectedTrack.hasOverrides {
            overrideBPM = selectedTrack.bpm > 0 ? String(format: "%.1f", selectedTrack.bpm) : ""
            overrideKey = selectedTrack.key
            overrideEnergy = String(format: "%.2f", selectedTrack.energy)
        }
    }

    private func previewSymbol(for track: Track) -> String {
        if previewPlayer.activeTrackID == track.id, previewPlayer.isPlaying {
            return "pause.circle.fill"
        }
        return "play.circle.fill"
    }

    private func previewButtonTitle(for track: Track) -> String {
        if previewPlayer.activeTrackID == track.id, previewPlayer.isPlaying {
            return "Stop Preview"
        }
        return "Play 30s Preview"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.scannedFolder = url.path
        }
    }

    private func scan() async {
        isBusy = true
        defer { isBusy = false }
        let folder = appState.scannedFolder
        beginAnalysisStatus(action: "Scanning Folder", detail: "Indexing and analyzing tracks from \(URL(fileURLWithPath: folder).lastPathComponent)", indeterminate: true)

        do {
            let status = try await Task.detached {
                try BackendClient().scan(directory: folder)
            }.value
            appState.statusMessage = status
            completeAnalysisStatus(detail: status, failed: false)
            await loadTracks()
        } catch {
            appState.statusMessage = "Scan failed: \(error.localizedDescription)"
            completeAnalysisStatus(detail: "Scan failed: \(error.localizedDescription)", failed: true)
        }
    }

    private func reanalyzeSelectedTracks() async {
        let ids = selectedTrackIDs.sorted()
        guard !ids.isEmpty else { return }
        await performBulkReanalysis(trackIDs: ids, action: "Reanalyzing Selected Tracks")
    }

    private func reanalyzeAllImportedTracks() async {
        isBusy = true
        beginAnalysisStatus(action: "Preparing Reanalyze All", detail: "Loading imported tracks...", indeterminate: true)
        do {
            let allTracks = try await Task.detached {
                try BackendClient().tracks(query: "", bpm: "", key: "", energy: "")
            }.value
            let ids = allTracks.map(\.id)
            if ids.isEmpty {
                appState.statusMessage = "No tracks available for reanalysis."
                completeAnalysisStatus(detail: "No tracks available for reanalysis.", failed: false)
                isBusy = false
                return
            }
            await performBulkReanalysis(trackIDs: ids, action: "Reanalyzing All Imported Tracks")
        } catch {
            appState.statusMessage = "Failed to load tracks for reanalysis: \(error.localizedDescription)"
            completeAnalysisStatus(detail: "Failed to load tracks for reanalysis.", failed: true)
            isBusy = false
        }
    }

    private func deleteSelectedTracks() async {
        let ids = selectedTrackIDs.sorted()
        guard !ids.isEmpty else { return }
        guard confirmDeleteTracks(count: ids.count) else { return }

        isBusy = true
        defer { isBusy = false }
        beginAnalysisStatus(
            action: "Removing Tracks",
            detail: "Deleting \(ids.count) track\(ids.count == 1 ? "" : "s") from library...",
            indeterminate: true
        )

        do {
            let summary = try await Task.detached {
                try BackendClient().deleteTracks(trackIDs: ids)
            }.value

            let status = deleteSummaryText(summary)
            appState.statusMessage = status
            completeAnalysisStatus(detail: status, failed: summary.deleted == 0 && summary.requested > 0)
            selectedTrackIDs.removeAll()
            previewPlayer.stopPreview(clearSelection: true)
            await loadTracks()
        } catch {
            let message = "Delete failed: \(error.localizedDescription)"
            appState.statusMessage = message
            completeAnalysisStatus(detail: message, failed: true)
        }
    }

    private func performBulkReanalysis(trackIDs: [Int], action: String) async {
        isBusy = true
        defer { isBusy = false }
        beginAnalysisStatus(action: action, detail: "Starting...", total: trackIDs.count, indeterminate: false)

        var success = 0
        var failures = 0

        for (index, trackID) in trackIDs.enumerated() {
            let trackLabel = trackLabelForID(trackID) ?? "Track \(trackID)"
            updateAnalysisStatusProgress(
                current: index + 1,
                detail: "[\(index + 1)/\(trackIDs.count)] \(trackLabel)"
            )

            do {
                let refreshed = try await Task.detached {
                    try BackendClient().reanalyze(trackID: trackID)
                }.value

                updateTrackInList(refreshed)
                success += 1
            } catch {
                failures += 1
            }
        }

        let summary = "Reanalysis finished: \(success)/\(trackIDs.count) updated" + (failures > 0 ? " (\(failures) failed)" : "")
        appState.statusMessage = summary
        completeAnalysisStatus(detail: summary, failed: failures > 0)
        await loadTracks()
        syncOverrideDrafts()
    }

    private func saveOverrides() async {
        guard let trackID = primarySelectedTrackID, selectionCount == 1 else { return }

        let bpmValue = parseOverride(overrideBPM)
        let energyValue = parseOverride(overrideEnergy)
        let keyValue = overrideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = keyValue.isEmpty ? nil : keyValue

        if !overrideBPM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bpmValue == nil {
            appState.statusMessage = "BPM override must be numeric."
            return
        }
        if !overrideEnergy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && energyValue == nil {
            appState.statusMessage = "Energy override must be numeric."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let updated = try await Task.detached {
                try BackendClient().overrideTrack(
                    trackID: trackID,
                    bpm: bpmValue,
                    key: normalizedKey,
                    energy: energyValue
                )
            }.value

            updateTrackInList(updated)
            appState.statusMessage = "Corrections saved: \(updated.displayName)"
            syncOverrideDrafts()
        } catch {
            appState.statusMessage = "Saving corrections failed: \(error.localizedDescription)"
        }
    }

    private func clearOverrides() async {
        guard let trackID = primarySelectedTrackID, selectionCount == 1 else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let updated = try await Task.detached {
                try BackendClient().overrideTrack(
                    trackID: trackID,
                    bpm: nil,
                    key: nil,
                    energy: nil,
                    clear: true
                )
            }.value

            updateTrackInList(updated)
            appState.statusMessage = "Corrections cleared: \(updated.displayName)"
            syncOverrideDrafts()
        } catch {
            appState.statusMessage = "Clearing corrections failed: \(error.localizedDescription)"
        }
    }

    private func loadTracks() async {
        isBusy = true
        defer { isBusy = false }

        let localQuery = query
        let localBPM = bpmRange
        let localKey = key
        let localEnergy = energyRange
        let localReviewOnly = reviewFilter == .reviewQueue

        do {
            let tracks = try await Task.detached {
                try BackendClient().tracks(
                    query: localQuery,
                    bpm: localBPM,
                    key: localKey,
                    energy: localEnergy,
                    needsReview: localReviewOnly
                )
            }.value

            appState.libraryTracks = tracks
            let visibleIDs = Set(tracks.map(\.id))
            let previousSelection = selectedTrackIDs
            selectedTrackIDs = selectedTrackIDs.intersection(visibleIDs)
            if !previousSelection.isEmpty && selectedTrackIDs.isEmpty {
                previewPlayer.stopPreview(clearSelection: true)
            }
            appState.statusMessage = "Loaded \(tracks.count) tracks"
            syncOverrideDrafts()
        } catch {
            appState.statusMessage = "Track load failed: \(error.localizedDescription)"
        }
    }

    private func updateTrackInList(_ track: Track) {
        if reviewFilter == .reviewQueue, !track.needsReview {
            appState.libraryTracks.removeAll { $0.id == track.id }
            if selectedTrackIDs.contains(track.id) {
                selectedTrackIDs.remove(track.id)
                previewPlayer.stopPreview(clearSelection: true)
            }
            return
        }

        if let index = appState.libraryTracks.firstIndex(where: { $0.id == track.id }) {
            appState.libraryTracks[index] = track
        } else {
            appState.libraryTracks.append(track)
        }
    }

    private func trackLabelForID(_ trackID: Int) -> String? {
        if let track = appState.libraryTracks.first(where: { $0.id == trackID }) {
            return track.displayName
        }
        return nil
    }

    private func beginAnalysisStatus(action: String, detail: String, total: Int = 0, indeterminate: Bool) {
        analysisStatus.action = action
        analysisStatus.detail = detail
        analysisStatus.total = total
        analysisStatus.current = 0
        analysisStatus.isRunning = true
        analysisStatus.isIndeterminate = indeterminate
        analysisStatus.isError = false
    }

    private func updateAnalysisStatusProgress(current: Int, detail: String) {
        analysisStatus.current = current
        analysisStatus.detail = detail
    }

    private func completeAnalysisStatus(detail: String, failed: Bool) {
        analysisStatus.detail = detail
        analysisStatus.current = analysisStatus.total
        analysisStatus.isRunning = false
        analysisStatus.isIndeterminate = false
        analysisStatus.isError = failed
        if failed {
            analysisStatus.action = "Analysis Completed with Issues"
        } else {
            analysisStatus.action = "Analysis Complete"
        }
    }

    private func parseOverride(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func confirmDeleteTracks(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "Delete selected track from library?"
            : "Delete \(count) selected tracks from library?"
        alert.informativeText = "This removes DeepCrate analysis data and set references. Audio files on disk are not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func deleteSummaryText(_ summary: DeleteTracksSummary) -> String {
        var parts: [String] = ["Deleted \(summary.deleted)/\(summary.requested) track\(summary.requested == 1 ? "" : "s")"]
        if summary.removedFromSets > 0 {
            parts.append("\(summary.removedFromSets) set entr\(summary.removedFromSets == 1 ? "y" : "ies") removed")
        }
        if summary.clearedGapSets > 0 {
            parts.append("gap analysis cleared for \(summary.clearedGapSets) set\(summary.clearedGapSets == 1 ? "" : "s")")
        }
        if summary.missing > 0 {
            parts.append("\(summary.missing) already missing")
        }
        return parts.joined(separator: " | ")
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 90, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
    }
}
