import Foundation

enum BackendError: LocalizedError {
    case pythonMissing(String)
    case processFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .pythonMissing(let path):
            return "Python runtime not found at \(path)."
        case .processFailed(let message):
            return message
        case .invalidResponse:
            return "Backend returned invalid JSON."
        }
    }
}

struct BackendClient {
    private var repoRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
    }

    private var pythonURL: URL {
        repoRoot.appendingPathComponent(".venv/bin/python")
    }

    private var bridgeScriptURL: URL {
        repoRoot.appendingPathComponent("deepcrate/mac_bridge.py")
    }

    func scan(directory: String) throws -> String {
        let result: ScanResponse = try runJSON(["scan", "--directory", directory])
        return "Found \(result.total) files | analyzed \(result.analyzed) | cached \(result.skipped) | errors \(result.errors)"
    }

    func reanalyze(trackID: Int) throws -> Track {
        let result: ReanalyzeResponse = try runJSON(["reanalyze", "--track-id", "\(trackID)"])
        let dto = result.track
        return Track(
            id: dto.id,
            artist: dto.artist,
            title: dto.title,
            bpm: dto.bpm,
            key: dto.musicalKey,
            energy: dto.energyLevel,
            energyConfidence: dto.energyConfidence,
            duration: dto.duration,
            filePath: dto.filePath,
            previewStart: dto.previewStart,
            needsReview: dto.needsReview,
            reviewNotes: dto.reviewNotes,
            hasOverrides: dto.hasOverrides
        )
    }

    func tracks(query: String, bpm: String, key: String, energy: String, needsReview: Bool = false) throws -> [Track] {
        var args = ["tracks"]
        if !query.isEmpty { args += ["--query", query] }
        if !bpm.isEmpty { args += ["--bpm", bpm] }
        if !key.isEmpty { args += ["--key", key] }
        if !energy.isEmpty { args += ["--energy", energy] }
        if needsReview { args.append("--needs-review") }

        let result: TracksResponse = try runJSON(args)
        return result.tracks.map {
            Track(
                id: $0.id,
                artist: $0.artist,
                title: $0.title,
                bpm: $0.bpm,
                key: $0.musicalKey,
                energy: $0.energyLevel,
                energyConfidence: $0.energyConfidence,
                duration: $0.duration,
                filePath: $0.filePath,
                previewStart: $0.previewStart,
                needsReview: $0.needsReview,
                reviewNotes: $0.reviewNotes,
                hasOverrides: $0.hasOverrides
            )
        }
    }

    func overrideTrack(
        trackID: Int,
        bpm: Double?,
        key: String?,
        energy: Double?,
        clear: Bool = false
    ) throws -> Track {
        var args = ["override-track", "--track-id", "\(trackID)"]
        if let bpm {
            args += ["--bpm", "\(bpm)"]
        }
        if let key, !key.isEmpty {
            args += ["--key", key]
        }
        if let energy {
            args += ["--energy", "\(energy)"]
        }
        if clear {
            args.append("--clear")
        }

        let result: ReanalyzeResponse = try runJSON(args)
        let dto = result.track
        return Track(
            id: dto.id,
            artist: dto.artist,
            title: dto.title,
            bpm: dto.bpm,
            key: dto.musicalKey,
            energy: dto.energyLevel,
            energyConfidence: dto.energyConfidence,
            duration: dto.duration,
            filePath: dto.filePath,
            previewStart: dto.previewStart,
            needsReview: dto.needsReview,
            reviewNotes: dto.reviewNotes,
            hasOverrides: dto.hasOverrides
        )
    }

    func deleteTracks(trackIDs: [Int]) throws -> DeleteTracksSummary {
        let unique = Array(Set(trackIDs.filter { $0 > 0 })).sorted()
        let encodedIDs = String(data: try JSONEncoder().encode(unique), encoding: .utf8) ?? "[]"
        let result: DeleteTracksResponse = try runJSON(
            [
                "delete-tracks",
                "--track-ids", encodedIDs,
            ]
        )
        return DeleteTracksSummary(
            requested: result.requested,
            deleted: result.deleted,
            missing: result.missing,
            removedFromSets: result.removedFromSets,
            clearedGapSets: result.clearedGapSets
        )
    }

    func plan(description: String, name: String, duration: Int) throws {
        _ = try runJSON(["plan", "--description", description, "--name", name, "--duration", "\(duration)"]) as PlanResponse
    }

    func sets() throws -> [SetSummary] {
        let result: SetsResponse = try runJSON(["sets"])
        return result.sets.map {
            SetSummary(id: $0.id, name: $0.name, description: $0.description, targetDuration: $0.targetDuration)
        }
    }

    func setTracks(name: String) throws -> [SetTrackRow] {
        let result: SetTracksResponse = try runJSON(["set-tracks", "--name", name])
        return result.rows.map {
            SetTrackRow(
                id: $0.position,
                position: $0.position,
                artist: $0.artist,
                title: $0.title,
                bpm: $0.bpm,
                key: $0.musicalKey,
                energy: $0.energyLevel,
                transition: $0.transition
            )
        }
    }

    func gaps(name: String) throws -> [GapSuggestion] {
        let result: GapsResponse = try runJSON(["gaps", "--name", name])
        return result.gaps.map {
            GapSuggestion(
                fromTrack: $0.from,
                toTrack: $0.to,
                score: $0.score,
                suggestedBPM: $0.suggestedBPM,
                suggestedKey: $0.suggestedKey
            )
        }
    }

    func discover(name: String, gap: Int, genre: String, limit: Int) throws -> [DiscoverSuggestion] {
        var args = ["discover", "--name", name, "--gap", "\(gap)", "--limit", "\(limit)"]
        if !genre.isEmpty {
            args += ["--genre", genre]
        }

        let result: DiscoverResponse = try runJSON(args)
        return result.results.map {
            DiscoverSuggestion(artist: $0.artist, title: $0.name, bpm: $0.bpm, energy: $0.energy, url: $0.spotifyURL)
        }
    }

    func export(name: String, format: String, output: String) throws -> String {
        var args = ["export", "--name", name, "--format", format]
        if !output.isEmpty {
            args += ["--output", output]
        }

        let result: ExportResponse = try runJSON(args)
        return result.path
    }

    func saveSet(name: String, description: String, duration: Int, trackIDs: [Int]) throws {
        let encodedIDs = String(data: try JSONEncoder().encode(trackIDs), encoding: .utf8) ?? "[]"
        _ = try runJSON(
            [
                "save-set",
                "--name", name,
                "--description", description,
                "--duration", "\(duration)",
                "--track-ids", encodedIDs,
            ]
        ) as SaveSetResponse
    }

    private func runJSON<T: Decodable>(_ args: [String]) throws -> T {
        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            throw BackendError.pythonMissing(pythonURL.path)
        }

        let process = Process()
        process.executableURL = pythonURL
        process.currentDirectoryURL = repoRoot
        process.arguments = [bridgeScriptURL.path] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BackendError.processFailed(stderrText.isEmpty ? "Backend failed." : stderrText)
        }

        do {
            return try JSONDecoder().decode(T.self, from: stdoutData)
        } catch {
            let raw = String(data: stdoutData, encoding: .utf8) ?? ""
            throw BackendError.processFailed("\(error.localizedDescription)\n\nRaw: \(raw)")
        }
    }
}

private struct ScanResponse: Decodable {
    let total: Int
    let analyzed: Int
    let skipped: Int
    let errors: Int
}

private struct ReanalyzeResponse: Decodable {
    let track: TrackDTO
}

struct DeleteTracksSummary: Equatable {
    let requested: Int
    let deleted: Int
    let missing: Int
    let removedFromSets: Int
    let clearedGapSets: Int
}

private struct TracksResponse: Decodable {
    let tracks: [TrackDTO]
}

private struct DeleteTracksResponse: Decodable {
    let requested: Int
    let deleted: Int
    let missing: Int
    let removedFromSets: Int
    let clearedGapSets: Int

    enum CodingKeys: String, CodingKey {
        case requested
        case deleted
        case missing
        case removedFromSets = "removed_from_sets"
        case clearedGapSets = "cleared_gap_sets"
    }
}

private struct TrackDTO: Decodable {
    let id: Int
    let artist: String
    let title: String
    let bpm: Double
    let musicalKey: String
    let energyLevel: Double
    let energyConfidence: Double
    let duration: Double
    let filePath: String
    let previewStart: Double
    let needsReview: Bool
    let reviewNotes: String
    let hasOverrides: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case artist
        case title
        case bpm
        case musicalKey = "musical_key"
        case energyLevel = "energy_level"
        case energyConfidence = "energy_confidence"
        case duration
        case filePath = "file_path"
        case previewStart = "preview_start"
        case needsReview = "needs_review"
        case reviewNotes = "review_notes"
        case hasOverrides = "has_overrides"
    }
}

private struct PlanResponse: Decodable {
    let ok: Bool
}

private struct SetsResponse: Decodable {
    let sets: [SetDTO]
}

private struct SetDTO: Decodable {
    let id: Int
    let name: String
    let description: String
    let targetDuration: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case targetDuration = "target_duration"
    }
}

private struct SetTracksResponse: Decodable {
    let rows: [SetTrackDTO]
}

private struct SetTrackDTO: Decodable {
    let position: Int
    let artist: String
    let title: String
    let bpm: Double
    let musicalKey: String
    let energyLevel: Double
    let transition: String

    enum CodingKeys: String, CodingKey {
        case position
        case artist
        case title
        case bpm
        case musicalKey = "musical_key"
        case energyLevel = "energy_level"
        case transition
    }
}

private struct GapsResponse: Decodable {
    let gaps: [GapDTO]
}

private struct GapDTO: Decodable {
    let from: String
    let to: String
    let score: Double
    let suggestedBPM: Double
    let suggestedKey: String

    enum CodingKeys: String, CodingKey {
        case from
        case to
        case score
        case suggestedBPM = "suggested_bpm"
        case suggestedKey = "suggested_key"
    }
}

private struct DiscoverResponse: Decodable {
    let results: [DiscoverDTO]
}

private struct DiscoverDTO: Decodable {
    let name: String
    let artist: String
    let bpm: Double
    let energy: Double
    let spotifyURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case artist
        case bpm
        case energy
        case spotifyURL = "spotify_url"
    }
}

private struct ExportResponse: Decodable {
    let path: String
}

private struct SaveSetResponse: Decodable {
    let ok: Bool
}
