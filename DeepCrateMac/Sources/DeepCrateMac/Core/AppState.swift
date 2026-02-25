import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var scannedFolder: String = ""
    @Published var libraryTracks: [Track] = []
    @Published var setSummaries: [SetSummary] = []
    @Published var gapSuggestions: [GapSuggestion] = []
    @Published var discoverResults: [DiscoverSuggestion] = []
    @Published var statusMessage: String = "Ready"
    @Published var isWorking: Bool = false
    @Published var activeTaskLabel: String = "Idle"
    @Published var progressCurrent: Int = 0
    @Published var progressTotal: Int = 0
    @Published var progressIndeterminate: Bool = true
    @Published var statusUpdatedAt: Date = .now

    func beginTask(_ label: String, total: Int = 0, indeterminate: Bool = true) {
        isWorking = true
        activeTaskLabel = label
        progressCurrent = 0
        progressTotal = total
        progressIndeterminate = indeterminate
        statusUpdatedAt = .now
    }

    func updateTaskProgress(current: Int, total: Int? = nil) {
        progressCurrent = current
        if let total {
            progressTotal = total
        }
        statusUpdatedAt = .now
    }

    func completeTask(label: String? = nil) {
        if let label {
            activeTaskLabel = label
        }
        if progressTotal > 0 {
            progressCurrent = progressTotal
        }
        isWorking = false
        progressIndeterminate = false
        statusUpdatedAt = .now
    }
}
