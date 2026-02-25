import SwiftUI

struct PlanView: View {
    private struct PromptPreset: Identifiable {
        let id = UUID()
        let title: String
        let setName: String
        let duration: Int
        let prompt: String
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var name: String = ""
    @State private var duration: Int = 60
    @State private var description: String = ""
    @State private var isPlanning = false
    @State private var inlineMessage: String = ""
    @State private var inlineMessageIsError = false

    private let presets: [PromptPreset] = [
        PromptPreset(
            title: "Liquid DnB Warmup",
            setName: "Liquid Warmup",
            duration: 60,
            prompt: "60 minute liquid dnb journey, start mellow, build to a peak around minute 40, then cool down"
        ),
        PromptPreset(
            title: "Hardstyle Peak Time",
            setName: "Hardstyle Peak",
            duration: 75,
            prompt: "75 minute hardstyle peak-time set, aggressive energy from the start, keep pressure high and finish strong"
        ),
        PromptPreset(
            title: "Afro House Sunset",
            setName: "Afro Sunset",
            duration: 90,
            prompt: "90 minute afrohouse set for sunset, organic groove opening, steady lift, warm emotional finish"
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Plan Set")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))

                Spacer()

                LiquidStatusBadge(
                    text: settings.plannerMode == .localApple ? "On-device Apple Model" : "Cloud OpenAI Model",
                    taskLabel: "Planner",
                    isWorking: isPlanning,
                    progressCurrent: 0,
                    progressTotal: 0,
                    indeterminate: true,
                    updatedAt: appState.statusUpdatedAt
                )
            }

            VStack(alignment: .leading, spacing: 12) {
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

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prompt")
                        .font(.headline)
                    Spacer()
                    Menu("Use Example") {
                        ForEach(presets) { preset in
                            Button(preset.title) {
                                applyPreset(preset)
                            }
                        }
                        Divider()
                        Button("Clear Prompt") {
                            clearPrompt()
                        }
                    }
                }

                TextField("Set name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Stepper("Duration: \(duration) min", value: $duration, in: 10...360)

                TextEditor(text: $description)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 210)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous)
                    )
                    .overlay(alignment: .topLeading) {
                        if normalizedDescription.isEmpty {
                            Text("Describe vibe, genre, energy arc, and context. Example: 60 min liquid dnb set, start mellow and peak at 40 min.")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                                .padding(.top, 13)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: LiquidMetrics.compactRadius, style: .continuous)
                            .stroke(.quaternary)
                            .allowsHitTesting(false)
                    )

                Text("If set name is empty or already used, DeepCrate auto-creates a unique name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .liquidCard(cornerRadius: LiquidMetrics.cardRadius, material: .ultraThinMaterial, contentPadding: 14, shadowOpacity: 0.04)

            HStack {
                Button {
                    Task { await planSet() }
                } label: {
                    Label(isPlanning ? "Planning..." : "Generate Set", systemImage: "wand.and.stars")
                }
                .disabled(isPlanning || normalizedDescription.isEmpty)
                .buttonStyle(.borderedProminent)

                Button("Clear") {
                    clearPrompt()
                }
                .buttonStyle(.bordered)
                .disabled(isPlanning)

                if let latest = latestSet {
                    Text("Latest: \(latest.name)")
                        .foregroundStyle(.secondary)
                }
            }
            .liquidCard(cornerRadius: LiquidMetrics.compactRadius, material: .ultraThinMaterial, contentPadding: 10, shadowOpacity: 0.04)

            if !inlineMessage.isEmpty {
                Label(inlineMessage, systemImage: inlineMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(inlineMessageIsError ? .red : .secondary)
            }
        }
        .task {
            await refreshSets()
        }
    }

    private func planSet() async {
        isPlanning = true
        appState.statusMessage = "Planning set..."
        defer { isPlanning = false }

        let localDescription = normalizedDescription
        if localDescription.isEmpty {
            inlineMessageIsError = true
            inlineMessage = "Add a prompt before generating."
            appState.statusMessage = "Set planning needs a prompt."
            return
        }

        let localName = resolvedSetName()
        let localDuration = duration
        name = localName

        var preflightWarning: String?
        do {
            let tracks = try await ensureLibraryTracks()
            let availability = LocalApplePlanner().evaluateGenreAvailability(
                description: localDescription,
                tracks: tracks
            )
            if let warning = availability.warningMessage {
                preflightWarning = warning
                inlineMessageIsError = false
                inlineMessage = "Warning: \(warning)"
                appState.statusMessage = warning
            }
        } catch {
            appState.statusMessage = "Could not pre-check genre availability: \(error.localizedDescription)"
        }

        if settings.plannerMode == .localApple {
            await planWithAppleModel(
                description: localDescription,
                name: localName,
                duration: localDuration,
                preflightWarning: preflightWarning
            )
            return
        }

        await planWithOpenAI(
            description: localDescription,
            name: localName,
            duration: localDuration,
            preflightWarning: preflightWarning
        )
    }

    private func planWithAppleModel(
        description: String,
        name: String,
        duration: Int,
        preflightWarning: String?
    ) async {
        do {
            let tracks = try await ensureLibraryTracks()

            let planner = LocalApplePlanner()
            let ids = try await planner.planTrackIDs(description: description, durationMinutes: duration, tracks: tracks)
            if ids.isEmpty {
                appState.statusMessage = "Apple model returned no tracks."
                return
            }

            try await Task.detached {
                try LocalDatabase.shared.saveSet(
                    name: name,
                    description: description,
                    duration: duration,
                    trackIDs: ids
                )
            }.value
            appState.statusMessage = "Created set \(name) with local Apple model"
            inlineMessageIsError = false
            if let preflightWarning {
                inlineMessage = "Created set \(name). Note: \(preflightWarning)"
            } else {
                inlineMessage = "Created set \(name)"
            }
            await refreshSets()
        } catch {
            appState.statusMessage = "Local planning failed: \(error.localizedDescription)"
            inlineMessageIsError = true
            inlineMessage = "Local planning failed: \(error.localizedDescription)"
        }
    }

    private func planWithOpenAI(
        description: String,
        name: String,
        duration: Int,
        preflightWarning: String?
    ) async {
        do {
            let tracks = try await ensureLibraryTracks()
            let key = resolvedOpenAIKey()
            let model = resolvedOpenAIModel()
            let planner = OpenAISetPlanner()
            let ids = try await planner.planTrackIDs(
                description: description,
                durationMinutes: duration,
                tracks: tracks,
                apiKey: key,
                model: model
            )
            if ids.isEmpty {
                appState.statusMessage = "OpenAI planner returned no tracks."
                return
            }

            try await Task.detached {
                try LocalDatabase.shared.saveSet(
                    name: name,
                    description: description,
                    duration: duration,
                    trackIDs: ids
                )
            }.value
            appState.statusMessage = "Created set \(name) with OpenAI"
            inlineMessageIsError = false
            if let preflightWarning {
                inlineMessage = "Created set \(name). Note: \(preflightWarning)"
            } else {
                inlineMessage = "Created set \(name)"
            }
            await refreshSets()
        } catch {
            appState.statusMessage = "OpenAI planning failed: \(error.localizedDescription)"
            inlineMessageIsError = true
            inlineMessage = "OpenAI planning failed: \(error.localizedDescription)"
        }
    }

    private func refreshSets() async {
        do {
            let sets = try await Task.detached {
                try LocalDatabase.shared.listSets()
            }.value
            appState.setSummaries = sets
        } catch {
            appState.statusMessage = "Failed to load sets: \(error.localizedDescription)"
        }
    }

    private func ensureLibraryTracks() async throws -> [Track] {
        if !appState.libraryTracks.isEmpty {
            return appState.libraryTracks
        }
        let tracks = try await Task.detached {
            try LocalDatabase.shared.loadTracks()
        }.value
        appState.libraryTracks = tracks
        return tracks
    }

    private func resolvedOpenAIKey() -> String {
        let fromSettings = settings.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromSettings.isEmpty {
            return fromSettings
        }
        return envValue("OPENAI_API_KEY") ?? ""
    }

    private func resolvedOpenAIModel() -> String {
        let fromSettings = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromSettings.isEmpty {
            return fromSettings
        }
        return envValue("OPENAI_MODEL") ?? "gpt-4o-mini"
    }

    private func envValue(_ key: String) -> String? {
        for envURL in AppRuntime.envFileCandidates {
            guard let content = try? String(contentsOf: envURL, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private var normalizedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestSet: SetSummary? {
        appState.setSummaries.max(by: { $0.id < $1.id })
    }

    private func clearPrompt() {
        name = ""
        duration = 60
        description = ""
    }

    private func applyPreset(_ preset: PromptPreset) {
        name = preset.setName
        duration = preset.duration
        description = preset.prompt
    }

    private func resolvedSetName() -> String {
        let baseName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = baseName.isEmpty ? defaultSetName() : baseName
        let existing = Set(appState.setSummaries.map { $0.name.lowercased() })

        if !existing.contains(seed.lowercased()) {
            return seed
        }

        var index = 2
        while true {
            let candidate = "\(seed) \(index)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    private func defaultSetName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return "Set \(formatter.string(from: Date()))"
    }
}
