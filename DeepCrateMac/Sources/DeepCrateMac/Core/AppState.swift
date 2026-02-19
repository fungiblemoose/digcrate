import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var scannedFolder: String = ""
    @Published var libraryTracks: [Track] = []
    @Published var setSummaries: [SetSummary] = []
    @Published var gapSuggestions: [GapSuggestion] = []
    @Published var discoverResults: [DiscoverSuggestion] = []
    @Published var statusMessage: String = "Ready"
}
