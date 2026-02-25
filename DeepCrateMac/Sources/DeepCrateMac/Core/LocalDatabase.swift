import Foundation
import SQLite3

enum LocalDatabaseError: LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case setNotFound(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Database open failed: \(message)"
        case .sqlite(let message):
            return message
        case .setNotFound(let name):
            return "Set not found: \(name)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let localDatabaseBootstrapSchema = """
CREATE TABLE IF NOT EXISTS tracks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT UNIQUE NOT NULL,
    file_hash TEXT NOT NULL,
    title TEXT DEFAULT '',
    artist TEXT DEFAULT '',
    bpm REAL DEFAULT 0.0,
    musical_key TEXT DEFAULT '',
    energy_level REAL DEFAULT 0.0,
    energy_confidence REAL DEFAULT 1.0,
    duration REAL DEFAULT 0.0,
    preview_start REAL DEFAULT 0.0,
    needs_review INTEGER DEFAULT 0,
    review_notes TEXT DEFAULT '',
    has_overrides INTEGER DEFAULT 0,
    analysis_version INTEGER DEFAULT 3
);

CREATE TABLE IF NOT EXISTS sets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    description TEXT DEFAULT '',
    target_duration INTEGER DEFAULT 60
);

CREATE TABLE IF NOT EXISTS set_tracks (
    set_id INTEGER NOT NULL,
    track_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    transition_score REAL DEFAULT 0.0,
    PRIMARY KEY (set_id, position)
);

CREATE TABLE IF NOT EXISTS gaps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    set_id INTEGER NOT NULL,
    position INTEGER NOT NULL,
    suggested_bpm REAL DEFAULT 0.0,
    suggested_key TEXT DEFAULT '',
    suggested_energy REAL DEFAULT 0.0,
    suggested_vibe TEXT DEFAULT ''
);

CREATE TABLE IF NOT EXISTS track_overrides (
    file_path TEXT PRIMARY KEY NOT NULL,
    bpm REAL,
    musical_key TEXT,
    energy_level REAL,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);
"""

final class LocalDatabase: @unchecked Sendable {
    static let shared = LocalDatabase()

    private init() {}

    private enum TransitionRiskMode: String {
        case safe = "Safe"
        case balanced = "Balanced"
        case bold = "Bold"
    }

    func listSets() throws -> [SetSummary] {
        try withConnection { db in
            let sql = "SELECT id, name, description, target_duration FROM sets ORDER BY id DESC"
            let stmt = try prepare(db: db, sql: sql)
            defer { sqlite3_finalize(stmt) }

            var rows: [SetSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    SetSummary(
                        id: intColumn(stmt, 0),
                        name: textColumn(stmt, 1),
                        description: textColumn(stmt, 2),
                        targetDuration: intColumn(stmt, 3)
                    )
                )
            }
            return rows
        }
    }

    func loadTracks() throws -> [Track] {
        try withConnection { db in
            let sql = """
            SELECT id, artist, title, bpm, musical_key, energy_level, energy_confidence, duration, file_path,
                   preview_start, needs_review, review_notes, has_overrides
            FROM tracks
            ORDER BY artist, title
            """
            let stmt = try prepare(db: db, sql: sql)
            defer { sqlite3_finalize(stmt) }

            var rows: [Track] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(
                    Track(
                        id: intColumn(stmt, 0),
                        artist: textColumn(stmt, 1),
                        title: textColumn(stmt, 2),
                        bpm: doubleColumn(stmt, 3),
                        key: textColumn(stmt, 4),
                        energy: doubleColumn(stmt, 5),
                        energyConfidence: doubleColumn(stmt, 6, fallback: 1.0),
                        duration: doubleColumn(stmt, 7),
                        filePath: textColumn(stmt, 8),
                        previewStart: doubleColumn(stmt, 9),
                        needsReview: intColumn(stmt, 10) == 1,
                        reviewNotes: textColumn(stmt, 11),
                        hasOverrides: intColumn(stmt, 12) == 1
                    )
                )
            }
            return rows
        }
    }

    func setTrackRows(name: String) throws -> [SetTrackRow] {
        try withConnection { db in
            let sql = """
            SELECT st.position, st.track_id, st.transition_score, t.artist, t.title, t.bpm, t.musical_key,
                   t.energy_level, t.file_path, t.preview_start
            FROM set_tracks st
            JOIN sets s ON s.id = st.set_id
            JOIN tracks t ON t.id = st.track_id
            WHERE s.name = ?
            ORDER BY st.position
            """
            let stmt = try prepare(db: db, sql: sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: name)

            var rows: [SetTrackRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let position = intColumn(stmt, 0)
                let trackID = intColumn(stmt, 1)
                let score = doubleColumn(stmt, 2)
                let artist = nonEmpty(textColumn(stmt, 3), fallback: "Unknown Artist")
                let title = displayTitle(
                    title: textColumn(stmt, 4),
                    filePath: textColumn(stmt, 8)
                )
                let transition = position <= 1 ? "" : "\(describeTransition(score)) (\(Int((score * 100).rounded()))%)"
                rows.append(
                    SetTrackRow(
                        id: position,
                        position: position,
                        trackID: trackID,
                        artist: artist,
                        title: title,
                        bpm: doubleColumn(stmt, 5),
                        key: textColumn(stmt, 6),
                        energy: doubleColumn(stmt, 7),
                        filePath: textColumn(stmt, 8),
                        previewStart: doubleColumn(stmt, 9),
                        transition: transition,
                        transitionScore: score,
                        keyScore: 0,
                        bpmScore: 0,
                        energyScore: 0,
                        phraseScore: 0
                    )
                )
            }

            if rows.count > 1 {
                for index in 1..<rows.count {
                    let previous = rows[index - 1]
                    let current = rows[index]
                    let components = transitionComponents(
                        from: Track(
                            id: previous.trackID,
                            artist: previous.artist,
                            title: previous.title,
                            bpm: previous.bpm,
                            key: previous.key,
                            energy: previous.energy
                        ),
                        to: Track(
                            id: current.trackID,
                            artist: current.artist,
                            title: current.title,
                            bpm: current.bpm,
                            key: current.key,
                            energy: current.energy
                        ),
                        fallbackScore: current.transitionScore
                    )
                    let updatedScore = transitionScore(from: components)
                    rows[index].transitionScore = updatedScore
                    rows[index].transition = "\(describeTransition(updatedScore)) (\(Int((updatedScore * 100).rounded()))%)"
                    rows[index].keyScore = components.key
                    rows[index].bpmScore = components.bpm
                    rows[index].energyScore = components.energy
                    rows[index].phraseScore = components.phrase
                }
            }
            return rows
        }
    }

    func saveSet(name: String, description: String, duration: Int, trackIDs: [Int]) throws {
        let orderedIDs = orderedUnique(trackIDs.filter { $0 > 0 })
        guard !orderedIDs.isEmpty else {
            throw LocalDatabaseError.sqlite("Cannot save an empty set.")
        }

        try withConnection { db in
            try beginTransaction(db)
            do {
                if let existingID = try setID(db: db, name: name) {
                    try exec(db: db, sql: "DELETE FROM set_tracks WHERE set_id = ?", bindings: { self.bindInt($0, index: 1, value: existingID) })
                    try exec(db: db, sql: "DELETE FROM gaps WHERE set_id = ?", bindings: { self.bindInt($0, index: 1, value: existingID) })
                    try exec(db: db, sql: "DELETE FROM sets WHERE id = ?", bindings: { self.bindInt($0, index: 1, value: existingID) })
                }

                try exec(
                    db: db,
                    sql: "INSERT INTO sets (name, description, target_duration) VALUES (?, ?, ?)",
                    bindings: {
                        self.bindText($0, index: 1, value: name)
                        self.bindText($0, index: 2, value: description)
                        self.bindInt($0, index: 3, value: duration)
                    }
                )
                let newSetID = Int(sqlite3_last_insert_rowid(db))
                let trackLookup = try tracksByID(db: db, ids: orderedIDs)

                var previous: Track?
                var position = 1
                for trackID in orderedIDs {
                    guard let track = trackLookup[trackID] else { continue }
                    let score = previous.map { transitionScore($0, track) } ?? 0
                    try exec(
                        db: db,
                        sql: "INSERT INTO set_tracks (set_id, track_id, position, transition_score) VALUES (?, ?, ?, ?)",
                        bindings: {
                            self.bindInt($0, index: 1, value: newSetID)
                            self.bindInt($0, index: 2, value: track.id)
                            self.bindInt($0, index: 3, value: position)
                            self.bindDouble($0, index: 4, value: score)
                        }
                    )
                    previous = track
                    position += 1
                }

                try commitTransaction(db)
            } catch {
                _ = try? rollbackTransaction(db)
                throw error
            }
        }
    }

    func analyzeGaps(name: String) throws -> [GapSuggestion] {
        try withConnection { db in
            guard let setID = try setID(db: db, name: name) else {
                throw LocalDatabaseError.setNotFound(name)
            }

            let orderedTracks = try tracksForSet(db: db, setID: setID)
            if orderedTracks.count < 2 {
                try exec(db: db, sql: "DELETE FROM gaps WHERE set_id = ?", bindings: {
                    self.bindInt($0, index: 1, value: setID)
                })
                return []
            }

            var suggestions: [GapSuggestion] = []
            var inserts: [(position: Int, bpm: Double, key: String, energy: Double)] = []
            var weakPosition = 1

            for index in 0..<(orderedTracks.count - 1) {
                let from = orderedTracks[index]
                let to = orderedTracks[index + 1]
                let score = transitionScore(from, to)
                if score >= 0.5 {
                    continue
                }

                let avgBPM = ((from.bpm + to.bpm) / 2.0).rounded(toPlaces: 1)
                let avgEnergy = ((from.energy + to.energy) / 2.0).rounded(toPlaces: 2)
                let suggestedKey = suggestedBridgeKey(from: from.key, to: to.key)
                let reason = weakReason(from: from, to: to)
                let candidates = try bridgeCandidates(
                    db: db,
                    from: from,
                    to: to,
                    targetBPM: avgBPM,
                    targetKey: suggestedKey,
                    targetEnergy: avgEnergy,
                    setID: setID
                )

                suggestions.append(
                    GapSuggestion(
                        fromTrack: from.displayName,
                        toTrack: to.displayName,
                        score: score,
                        suggestedBPM: avgBPM,
                        suggestedKey: suggestedKey,
                        weakReason: reason,
                        bridgeCandidates: candidates
                    )
                )
                inserts.append((position: weakPosition, bpm: avgBPM, key: suggestedKey, energy: avgEnergy))
                weakPosition += 1
            }

            try beginTransaction(db)
            do {
                try exec(db: db, sql: "DELETE FROM gaps WHERE set_id = ?", bindings: {
                    self.bindInt($0, index: 1, value: setID)
                })

                for row in inserts {
                    try exec(
                        db: db,
                        sql: "INSERT INTO gaps (set_id, position, suggested_bpm, suggested_key, suggested_energy, suggested_vibe) VALUES (?, ?, ?, ?, ?, ?)",
                        bindings: {
                            self.bindInt($0, index: 1, value: setID)
                            self.bindInt($0, index: 2, value: row.position)
                            self.bindDouble($0, index: 3, value: row.bpm)
                            self.bindText($0, index: 4, value: row.key)
                            self.bindDouble($0, index: 5, value: row.energy)
                            self.bindText($0, index: 6, value: "bridge track")
                        }
                    )
                }

                try commitTransaction(db)
            } catch {
                _ = try? rollbackTransaction(db)
                throw error
            }

            return suggestions
        }
    }

    private func withConnection<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let dbURL = resolvedDatabaseURL()
        do {
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw LocalDatabaseError.openFailed(error.localizedDescription)
        }
        let path = dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite error"
            if let db { sqlite3_close(db) }
            throw LocalDatabaseError.openFailed(message)
        }
        guard let db else {
            throw LocalDatabaseError.openFailed("No database handle.")
        }
        defer { sqlite3_close(db) }
        try ensureSchema(db)
        return try block(db)
    }

    private func resolvedDatabaseURL() -> URL {
        let configured = UserDefaults.standard.string(forKey: "settings.databasePath")
        return AppRuntime.resolveDatabaseURL(configuredPath: configured)
    }

    private func ensureSchema(_ db: OpaquePointer) throws {
        if sqlite3_exec(db, localDatabaseBootstrapSchema, nil, nil, nil) != SQLITE_OK {
            throw LocalDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func beginTransaction(_ db: OpaquePointer) throws {
        try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION")
    }

    private func commitTransaction(_ db: OpaquePointer) throws {
        try exec(db: db, sql: "COMMIT")
    }

    private func rollbackTransaction(_ db: OpaquePointer) throws {
        try exec(db: db, sql: "ROLLBACK")
    }

    private func setID(db: OpaquePointer, name: String) throws -> Int? {
        let stmt = try prepare(db: db, sql: "SELECT id FROM sets WHERE name = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return intColumn(stmt, 0)
        }
        return nil
    }

    private func tracksForSet(db: OpaquePointer, setID: Int) throws -> [Track] {
        let sql = """
        SELECT t.id, t.artist, t.title, t.bpm, t.musical_key, t.energy_level, t.energy_confidence, t.duration,
               t.file_path, t.preview_start, t.needs_review, t.review_notes, t.has_overrides
        FROM set_tracks st
        JOIN tracks t ON t.id = st.track_id
        WHERE st.set_id = ?
        ORDER BY st.position
        """
        let stmt = try prepare(db: db, sql: sql)
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, index: 1, value: setID)

        var rows: [Track] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                Track(
                    id: intColumn(stmt, 0),
                    artist: textColumn(stmt, 1),
                    title: textColumn(stmt, 2),
                    bpm: doubleColumn(stmt, 3),
                    key: textColumn(stmt, 4),
                    energy: doubleColumn(stmt, 5),
                    energyConfidence: doubleColumn(stmt, 6, fallback: 1.0),
                    duration: doubleColumn(stmt, 7),
                    filePath: textColumn(stmt, 8),
                    previewStart: doubleColumn(stmt, 9),
                    needsReview: intColumn(stmt, 10) == 1,
                    reviewNotes: textColumn(stmt, 11),
                    hasOverrides: intColumn(stmt, 12) == 1
                )
            )
        }
        return rows
    }

    private func tracksByID(db: OpaquePointer, ids: [Int]) throws -> [Int: Track] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT id, artist, title, bpm, musical_key, energy_level, energy_confidence, duration,
               file_path, preview_start, needs_review, review_notes, has_overrides
        FROM tracks
        WHERE id IN (\(placeholders))
        """
        let stmt = try prepare(db: db, sql: sql)
        defer { sqlite3_finalize(stmt) }
        for (index, id) in ids.enumerated() {
            bindInt(stmt, index: Int32(index + 1), value: id)
        }

        var rows: [Int: Track] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let track = Track(
                id: intColumn(stmt, 0),
                artist: textColumn(stmt, 1),
                title: textColumn(stmt, 2),
                bpm: doubleColumn(stmt, 3),
                key: textColumn(stmt, 4),
                energy: doubleColumn(stmt, 5),
                energyConfidence: doubleColumn(stmt, 6, fallback: 1.0),
                duration: doubleColumn(stmt, 7),
                filePath: textColumn(stmt, 8),
                previewStart: doubleColumn(stmt, 9),
                needsReview: intColumn(stmt, 10) == 1,
                reviewNotes: textColumn(stmt, 11),
                hasOverrides: intColumn(stmt, 12) == 1
            )
            rows[track.id] = track
        }
        return rows
    }

    private func prepare(db: OpaquePointer, sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw LocalDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else {
            throw LocalDatabaseError.sqlite("Failed to prepare statement.")
        }
        return stmt
    }

    private func exec(
        db: OpaquePointer,
        sql: String,
        bindings: ((OpaquePointer) -> Void)? = nil
    ) throws {
        let stmt = try prepare(db: db, sql: sql)
        defer { sqlite3_finalize(stmt) }
        bindings?(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw LocalDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func bindInt(_ stmt: OpaquePointer, index: Int32, value: Int) {
        sqlite3_bind_int(stmt, index, Int32(value))
    }

    private func bindDouble(_ stmt: OpaquePointer, index: Int32, value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int(stmt, index))
    }

    private func doubleColumn(_ stmt: OpaquePointer, _ index: Int32, fallback: Double = 0) -> Double {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL {
            return fallback
        }
        return sqlite3_column_double(stmt, index)
    }

    private func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func orderedUnique(_ ids: [Int]) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    private func displayTitle(title: String, filePath: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let path = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return "Unknown Track"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func describeTransition(_ score: Double) -> String {
        if score >= 0.85 { return "Excellent" }
        if score >= 0.7 { return "Good" }
        if score >= 0.5 { return "Decent" }
        if score >= 0.3 { return "Rough" }
        return "Clash"
    }

    private func transitionScore(_ a: Track, _ b: Track) -> Double {
        transitionScore(from: transitionComponents(from: a, to: b, fallbackScore: 0.5))
    }

    private func transitionScore(from components: (key: Double, bpm: Double, energy: Double, phrase: Double)) -> Double {
        let risk = transitionRiskMode()
        let weights: (Double, Double, Double, Double)
        switch risk {
        case .safe:
            weights = (0.42, 0.34, 0.18, 0.06)
        case .bold:
            weights = (0.28, 0.27, 0.31, 0.14)
        case .balanced:
            weights = (0.36, 0.32, 0.22, 0.10)
        }
        return (
            (weights.0 * components.key)
            + (weights.1 * components.bpm)
            + (weights.2 * components.energy)
            + (weights.3 * components.phrase)
        ).rounded(toPlaces: 2)
    }

    private func transitionRiskMode() -> TransitionRiskMode {
        let value = UserDefaults.standard.string(forKey: "settings.transitionRiskMode") ?? TransitionRiskMode.balanced.rawValue
        return TransitionRiskMode(rawValue: value) ?? .balanced
    }

    private func transitionComponents(from: Track?, to: Track?, fallbackScore: Double) -> (key: Double, bpm: Double, energy: Double, phrase: Double) {
        guard let from, let to else {
            return (key: fallbackScore, bpm: fallbackScore, energy: fallbackScore, phrase: fallbackScore)
        }
        return (
            key: keyCompatibility(from.key, to.key),
            bpm: bpmCompatibility(from.bpm, to.bpm),
            energy: energyFlow(from.energy, to.energy),
            phrase: phraseCompatibility(from: from, to: to)
        )
    }

    private func weakReason(from: Track, to: Track) -> String {
        let components = transitionComponents(from: from, to: to, fallbackScore: 0.5)
        let lowest = min(components.key, components.bpm, components.energy, components.phrase)
        if lowest == components.key {
            return "Harmonic mismatch is the main issue. Try a bridge in a compatible Camelot key."
        }
        if lowest == components.bpm {
            return "Tempo jump is the main issue. Use a bridge track closer to both BPMs."
        }
        if lowest == components.phrase {
            return "Phrase structure is awkward. Try a bridge with intro/outro sections that phrase cleanly."
        }
        return "Energy swing is the main issue. Insert a track with midpoint intensity."
    }

    private func bridgeCandidates(
        db: OpaquePointer,
        from: Track,
        to: Track,
        targetBPM: Double,
        targetKey: String,
        targetEnergy: Double,
        setID: Int
    ) throws -> [String] {
        let sql = """
        SELECT t.artist, t.title, t.bpm, t.musical_key, t.energy_level, t.duration
        FROM tracks t
        WHERE t.id NOT IN (SELECT track_id FROM set_tracks WHERE set_id = ?)
        LIMIT 200
        """
        let stmt = try prepare(db: db, sql: sql)
        defer { sqlite3_finalize(stmt) }
        bindInt(stmt, index: 1, value: setID)

        var scored: [(name: String, score: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let artist = nonEmpty(textColumn(stmt, 0), fallback: "Unknown Artist")
            let title = displayTitle(title: textColumn(stmt, 1), filePath: "")
            let bpm = doubleColumn(stmt, 2)
            let key = textColumn(stmt, 3)
            let energy = doubleColumn(stmt, 4)
            let duration = doubleColumn(stmt, 5)

            let bpmScore = bpmCompatibility(targetBPM, bpm)
            let keyScore = max(
                keyCompatibility(from.key, key),
                keyCompatibility(key, to.key),
                keyCompatibility(targetKey, key)
            )
            let energyScore = max(0.0, 1.0 - abs(targetEnergy - energy))
            let phraseScore = phraseCompatibility(
                from: from,
                to: Track(id: 0, artist: artist, title: title, bpm: bpm, key: key, energy: energy, duration: duration)
            )
            let total = transitionScore(from: (key: keyScore, bpm: bpmScore, energy: energyScore, phrase: phraseScore))
            if total < 0.55 {
                continue
            }
            scored.append((name: "\(artist) - \(title)", score: total))
        }

        return scored
            .sorted(by: { $0.score > $1.score })
            .prefix(3)
            .map(\.name)
    }

    private func bpmCompatibility(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs > 0, rhs > 0 else { return 0.5 }
        let diffs = [
            abs(lhs - rhs),
            abs(lhs - rhs * 2.0),
            abs(lhs * 2.0 - rhs),
        ]
        let diff = diffs.min() ?? abs(lhs - rhs)
        switch diff {
        case ...1.0: return 1.0
        case ...3.0: return 0.9
        case ...6.0: return 0.7
        case ...10.0: return 0.5
        case ...15.0: return 0.3
        default: return 0.1
        }
    }

    private func energyFlow(_ lhs: Double, _ rhs: Double) -> Double {
        let absDiff = abs(rhs - lhs)
        let score: Double
        switch absDiff {
        case let x where x > 0.5:
            score = 0.2
        case let x where x > 0.3:
            score = 0.5
        case let x where x > 0.15:
            score = 0.7
        default:
            score = 0.9
        }
        return score.rounded(toPlaces: 2)
    }

    private func phraseCompatibility(from: Track, to: Track) -> Double {
        guard from.bpm > 0, to.bpm > 0, from.duration > 0, to.duration > 0 else { return 0.6 }

        let fromBars = estimatedBars(duration: from.duration, bpm: from.bpm)
        let toBars = estimatedBars(duration: to.duration, bpm: to.bpm)
        let fromFit = nearestPhraseBlockFit(fromBars)
        let toFit = nearestPhraseBlockFit(toBars)
        return ((fromFit + toFit) / 2.0).rounded(toPlaces: 2)
    }

    private func estimatedBars(duration: Double, bpm: Double) -> Double {
        (duration * bpm) / 240.0
    }

    private func nearestPhraseBlockFit(_ bars: Double) -> Double {
        guard bars > 0 else { return 0.4 }
        let blocks = [8.0, 16.0, 32.0, 64.0]
        var best = 0.0
        for block in blocks {
            let remainder = bars.truncatingRemainder(dividingBy: block)
            let distance = min(remainder, block - remainder)
            let fit = max(0.0, 1.0 - (distance / (block / 2.0)))
            best = max(best, fit)
        }
        return best
    }

    private func keyCompatibility(_ lhs: String, _ rhs: String) -> Double {
        guard let a = parseCamelot(lhs), let b = parseCamelot(rhs) else { return 0.5 }
        if a.number == b.number && a.letter == b.letter { return 1.0 }
        if a.number == b.number && a.letter != b.letter { return 0.8 }
        if a.letter == b.letter {
            let distance = min(abs(a.number - b.number), 12 - abs(a.number - b.number))
            if distance == 1 { return 0.8 }
            if distance == 2 { return 0.5 }
        }
        return 0.2
    }

    private func suggestedBridgeKey(from lhs: String, to rhs: String) -> String {
        let a = Set(compatibleKeys(lhs))
        let b = Set(compatibleKeys(rhs))
        let common = a.intersection(b)
        if !common.isEmpty {
            return common.sorted(by: camelotAscending).first ?? lhs
        }
        return lhs
    }

    private func compatibleKeys(_ key: String) -> [String] {
        guard let parsed = parseCamelot(key) else { return [key] }
        let down = parsed.number == 1 ? 12 : parsed.number - 1
        let up = parsed.number == 12 ? 1 : parsed.number + 1
        return [
            "\(parsed.number)\(parsed.letter)",
            "\(parsed.number)\(parsed.letter == "A" ? "B" : "A")",
            "\(down)\(parsed.letter)",
            "\(up)\(parsed.letter)",
        ]
    }

    private func parseCamelot(_ value: String) -> (number: Int, letter: Character)? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let letter = normalized.last, letter == "A" || letter == "B" else { return nil }
        guard let number = Int(normalized.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }

    private func camelotAscending(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = parseCamelot(lhs), let b = parseCamelot(rhs) else { return lhs < rhs }
        if a.number == b.number {
            return a.letter < b.letter
        }
        return a.number < b.number
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
