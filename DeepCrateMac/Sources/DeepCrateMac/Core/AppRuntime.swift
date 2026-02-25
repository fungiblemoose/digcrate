import Foundation

enum AppRuntime {
    private static let bundleRuntimeDirectory = "DeepCrateRuntime"
    private static let appSupportSubdirectory = "DeepCrate"

    static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    static var usesEmbeddedBackend: Bool {
        bundledRuntimeRoot != nil
    }

    static var runtimeRoot: URL {
        if let bundledRuntimeRoot {
            return bundledRuntimeRoot
        }
        return devRepoRoot
    }

    static var backendWorkingDirectory: URL {
        usesEmbeddedBackend ? appSupportDirectory : runtimeRoot
    }

    static var envFileCandidates: [URL] {
        if usesEmbeddedBackend {
            return [
                appSupportDirectory.appendingPathComponent(".env"),
                runtimeRoot.appendingPathComponent(".env"),
            ]
        }
        return [runtimeRoot.appendingPathComponent(".env")]
    }

    static var defaultDatabaseSettingValue: String {
        if usesEmbeddedBackend {
            return defaultDatabaseURL.path
        }
        return "data/deepcrate.sqlite"
    }

    static var defaultDatabaseURL: URL {
        if usesEmbeddedBackend {
            return appSupportDirectory
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("deepcrate.sqlite")
        }
        return runtimeRoot
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("deepcrate.sqlite")
    }

    static func resolveDatabaseURL(configuredPath: String?) -> URL {
        let trimmed = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        let relative = trimmed.isEmpty ? "data/deepcrate.sqlite" : trimmed
        let base = usesEmbeddedBackend ? appSupportDirectory : runtimeRoot
        return base.appendingPathComponent(relative)
    }

    static var pythonExecutableURL: URL? {
        let candidates = [
            runtimeRoot.appendingPathComponent(".venv/bin/python3"),
            runtimeRoot.appendingPathComponent(".venv/bin/python"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static var expectedPythonLocationDescription: String {
        runtimeRoot.appendingPathComponent(".venv/bin/python").path
    }

    static var bridgeScriptURL: URL {
        runtimeRoot.appendingPathComponent("deepcrate/mac_bridge.py")
    }

    static var appSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let target = base.appendingPathComponent(appSupportSubdirectory, isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
        return target
    }

    private static var bundledRuntimeRoot: URL? {
        guard isBundledApp, let resourcesURL = Bundle.main.resourceURL else { return nil }
        let runtime = resourcesURL.appendingPathComponent(bundleRuntimeDirectory, isDirectory: true)
        return FileManager.default.fileExists(atPath: runtime.path) ? runtime : nil
    }

    private static var devRepoRoot: URL {
        if let located = locateRepoRoot() {
            return located
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
    }

    private static func locateRepoRoot() -> URL? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)

        while true {
            let pyproject = current.appendingPathComponent("pyproject.toml")
            let bridge = current.appendingPathComponent("deepcrate/mac_bridge.py")
            if fm.fileExists(atPath: pyproject.path), fm.fileExists(atPath: bridge.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }
}
