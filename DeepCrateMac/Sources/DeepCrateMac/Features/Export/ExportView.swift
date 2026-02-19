import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedSetID: Int?
    @State private var format: String = "m3u"
    @State private var outputPath: String = "~/Downloads/DeepCrate_Set.m3u"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            GroupBox("Export Options") {
                Picker("Set", selection: $selectedSetID) {
                    Text("Select Set").tag(Optional<Int>.none)
                    ForEach(appState.setSummaries) { setPlan in
                        Text(setPlan.name).tag(Optional(setPlan.id))
                    }
                }
                .frame(maxWidth: 360)

                Picker("Format", selection: $format) {
                    Text("m3u").tag("m3u")
                    Text("rekordbox xml").tag("xml")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: format) { _, newValue in
                    updateOutputExtension(for: newValue)
                }

                TextField("Output Path", text: $outputPath)
                    .textFieldStyle(.roundedBorder)

                Button("Export Current Set") {
                    Task { await exportSet() }
                }
                .buttonStyle(.borderedProminent)
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.05)
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

    private func exportSet() async {
        guard let selectedSet = appState.setSummaries.first(where: { $0.id == selectedSetID }) else {
            appState.statusMessage = "No set selected"
            return
        }
        let name = selectedSet.name
        let localFormat = format
        let localOutput = outputPath

        do {
            let path = try await Task.detached {
                try BackendClient().export(name: name, format: localFormat, output: localOutput)
            }.value
            appState.statusMessage = "Exported to \(path)"
        } catch {
            appState.statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func updateOutputExtension(for selectedFormat: String) {
        let normalized = selectedFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expected = normalized == "m3u" ? "m3u" : "xml"
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let current = url.pathExtension.lowercased()
        guard !current.isEmpty, current != expected else { return }

        let adjusted = url.deletingPathExtension().appendingPathExtension(expected)
        let home = NSHomeDirectory()
        if adjusted.path.hasPrefix(home + "/") {
            outputPath = "~" + adjusted.path.dropFirst(home.count)
        } else {
            outputPath = adjusted.path
        }
    }
}
