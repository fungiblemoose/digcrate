import Foundation

@MainActor
final class AppSettings: ObservableObject {
    enum PlannerMode: String, CaseIterable, Identifiable {
        case localApple = "Local Apple Model"
        case openAI = "OpenAI"

        var id: String { rawValue }
    }

    enum TransitionRiskMode: String, CaseIterable, Identifiable {
        case safe = "Safe"
        case balanced = "Balanced"
        case bold = "Bold"

        var id: String { rawValue }
    }

    @Published var openAIKey: String {
        didSet { UserDefaults.standard.set(openAIKey, forKey: Keys.openAIKey) }
    }
    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel) }
    }
    @Published var spotifyClientID: String {
        didSet { UserDefaults.standard.set(spotifyClientID, forKey: Keys.spotifyClientID) }
    }
    @Published var spotifyClientSecret: String {
        didSet { UserDefaults.standard.set(spotifyClientSecret, forKey: Keys.spotifyClientSecret) }
    }
    @Published var databasePath: String {
        didSet { UserDefaults.standard.set(databasePath, forKey: Keys.databasePath) }
    }
    @Published var plannerMode: PlannerMode {
        didSet { UserDefaults.standard.set(plannerMode.rawValue, forKey: Keys.plannerMode) }
    }
    @Published var transitionRiskMode: TransitionRiskMode {
        didSet { UserDefaults.standard.set(transitionRiskMode.rawValue, forKey: Keys.transitionRiskMode) }
    }

    init() {
        self.openAIKey = UserDefaults.standard.string(forKey: Keys.openAIKey) ?? ""
        self.openAIModel = UserDefaults.standard.string(forKey: Keys.openAIModel) ?? "gpt-4o-mini"
        self.spotifyClientID = UserDefaults.standard.string(forKey: Keys.spotifyClientID) ?? ""
        self.spotifyClientSecret = UserDefaults.standard.string(forKey: Keys.spotifyClientSecret) ?? ""
        self.databasePath = UserDefaults.standard.string(forKey: Keys.databasePath) ?? AppRuntime.defaultDatabaseSettingValue

        let storedMode = UserDefaults.standard.string(forKey: Keys.plannerMode)
        self.plannerMode = PlannerMode(rawValue: storedMode ?? "") ?? .localApple

        let storedRisk = UserDefaults.standard.string(forKey: Keys.transitionRiskMode)
        self.transitionRiskMode = TransitionRiskMode(rawValue: storedRisk ?? "") ?? .balanced
    }
}

private enum Keys {
    static let openAIKey = "settings.openAIKey"
    static let openAIModel = "settings.openAIModel"
    static let spotifyClientID = "settings.spotifyClientID"
    static let spotifyClientSecret = "settings.spotifyClientSecret"
    static let databasePath = "settings.databasePath"
    static let plannerMode = "settings.plannerMode"
    static let transitionRiskMode = "settings.transitionRiskMode"
}
