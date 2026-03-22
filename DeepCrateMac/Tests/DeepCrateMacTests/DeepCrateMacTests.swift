import Foundation
import SQLite3
import XCTest
@testable import DeepCrateMac

final class DeepCrateMacTests: XCTestCase {
    func testSearchTracksIncludesLegacyAnalysisInReviewQueue() throws {
        try withTemporaryDatabase { dbURL in
            try bootstrapDatabase()
            try seedTrack(
                dbURL: dbURL,
                id: 1,
                filePath: "/tmp/legacy.mp3",
                title: "Legacy Roller",
                artist: "DJ Legacy",
                bpm: 174.0,
                key: "8A",
                energy: 0.63,
                duration: 240.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 2
            )
            try seedTrack(
                dbURL: dbURL,
                id: 2,
                filePath: "/tmp/current.mp3",
                title: "Current Roller",
                artist: "DJ Current",
                bpm: 175.0,
                key: "9A",
                energy: 0.68,
                duration: 245.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 3
            )

            let reviewTracks = try LocalDatabase.shared.searchTracks(
                query: "",
                bpmRange: "",
                key: "",
                energyRange: "",
                needsReview: true
            )

            XCTAssertEqual(reviewTracks.map(\.id), [1])
            XCTAssertTrue(reviewTracks[0].needsReview)
            XCTAssertTrue(reviewTracks[0].reviewNotes.contains("Legacy analysis version; rescan to upgrade"))
        }
    }

    func testDeleteTracksRemovesDependentRows() throws {
        try withTemporaryDatabase { dbURL in
            try bootstrapDatabase()
            try seedTrack(
                dbURL: dbURL,
                id: 1,
                filePath: "/tmp/delete-me.mp3",
                title: "Delete Me",
                artist: "DJ Alpha",
                bpm: 128.0,
                key: "8A",
                energy: 0.52,
                duration: 220.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 3
            )
            try seedTrack(
                dbURL: dbURL,
                id: 2,
                filePath: "/tmp/keep-me.mp3",
                title: "Keep Me",
                artist: "DJ Beta",
                bpm: 129.0,
                key: "9A",
                energy: 0.57,
                duration: 226.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 3
            )
            try seedSet(dbURL: dbURL, id: 1, name: "Delete Test", description: "Test", duration: 60)
            try seedSetTrack(dbURL: dbURL, setID: 1, trackID: 1, position: 1, score: 0.0)
            try seedSetTrack(dbURL: dbURL, setID: 1, trackID: 2, position: 2, score: 0.82)
            try seedGap(dbURL: dbURL, setID: 1, position: 1)
            try seedOverride(dbURL: dbURL, filePath: "/tmp/delete-me.mp3", bpm: 127.5, key: "8A", energy: 0.5)

            let summary = try LocalDatabase.shared.deleteTracks(trackIDs: [1])

            XCTAssertEqual(summary.requested, 1)
            XCTAssertEqual(summary.deleted, 1)
            XCTAssertEqual(summary.missing, 0)
            XCTAssertEqual(summary.removedFromSets, 1)
            XCTAssertEqual(summary.clearedGapSets, 1)

            XCTAssertEqual(try countRows(dbURL: dbURL, table: "tracks"), 1)
            XCTAssertEqual(try countRows(dbURL: dbURL, table: "set_tracks"), 1)
            XCTAssertEqual(try countRows(dbURL: dbURL, table: "gaps"), 0)
            XCTAssertEqual(try countRows(dbURL: dbURL, table: "track_overrides"), 0)
        }
    }

    func testExportServiceWritesM3UAndRekordboxXML() throws {
        try withTemporaryDatabase { dbURL in
            try bootstrapDatabase()
            try seedTrack(
                dbURL: dbURL,
                id: 1,
                filePath: "/tmp/Track One.mp3",
                title: "Track One",
                artist: "Artist One",
                bpm: 128.0,
                key: "8A",
                energy: 0.58,
                duration: 240.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 3
            )
            try seedTrack(
                dbURL: dbURL,
                id: 2,
                filePath: "/tmp/Second Song.aiff",
                title: "",
                artist: "",
                bpm: 130.5,
                key: "9A",
                energy: 0.62,
                duration: 300.0,
                needsReview: false,
                reviewNotes: "",
                hasOverrides: false,
                analysisVersion: 3
            )
            try seedSet(dbURL: dbURL, id: 1, name: "Sunset / Set", description: "Export test", duration: 90)
            try seedSetTrack(dbURL: dbURL, setID: 1, trackID: 1, position: 1, score: 0.0)
            try seedSetTrack(dbURL: dbURL, setID: 1, trackID: 2, position: 2, score: 0.77)

            let exportDir = dbURL.deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
            let m3uPath = exportDir.appendingPathComponent("sunset.m3u")
            let xmlPath = exportDir.appendingPathComponent("sunset.xml")

            let m3uResult = try ExportService().exportSet(name: "Sunset / Set", format: "m3u", outputPath: m3uPath.path)
            let xmlResult = try ExportService().exportSet(name: "Sunset / Set", format: "xml", outputPath: xmlPath.path)

            XCTAssertEqual(m3uResult, m3uPath.path)
            XCTAssertEqual(xmlResult, xmlPath.path)

            let m3uContents = try String(contentsOf: m3uPath, encoding: .utf8)
            XCTAssertTrue(m3uContents.contains("#EXTM3U"))
            XCTAssertTrue(m3uContents.contains("#PLAYLIST:Sunset / Set"))
            XCTAssertTrue(m3uContents.contains("#EXTINF:240,Artist One - Track One"))
            XCTAssertTrue(m3uContents.contains("/tmp/Track One.mp3"))
            XCTAssertTrue(m3uContents.contains("#EXTINF:300,Second Song"))

            let xmlContents = try String(contentsOf: xmlPath, encoding: .utf8)
            XCTAssertTrue(xmlContents.contains(#"<PRODUCT Name="DeepCrate" Version="0.1.0"/>"#))
            XCTAssertTrue(xmlContents.contains(#"Name="Track One" Artist="Artist One""#))
            XCTAssertTrue(xmlContents.contains(#"Name="Second Song" Artist="""#))
            XCTAssertTrue(xmlContents.contains(#"Location="file://localhost/tmp/Track%20One.mp3""#))
            XCTAssertTrue(xmlContents.contains(#"<NODE Type="1" Name="Sunset / Set" KeyType="0" Entries="2">"#))
        }
    }

    private func withTemporaryDatabase(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let dbURL = tempDirectory.appendingPathComponent("deepcrate.sqlite")
        let previous = UserDefaults.standard.string(forKey: "settings.databasePath")
        UserDefaults.standard.set(dbURL.path, forKey: "settings.databasePath")

        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "settings.databasePath")
            } else {
                UserDefaults.standard.removeObject(forKey: "settings.databasePath")
            }
            try? fileManager.removeItem(at: tempDirectory)
        }

        try body(dbURL)
    }

    private func bootstrapDatabase() throws {
        _ = try LocalDatabase.shared.listSets()
    }

    private func seedTrack(
        dbURL: URL,
        id: Int,
        filePath: String,
        title: String,
        artist: String,
        bpm: Double,
        key: String,
        energy: Double,
        duration: Double,
        needsReview: Bool,
        reviewNotes: String,
        hasOverrides: Bool,
        analysisVersion: Int
    ) throws {
        try withSQLiteConnection(to: dbURL) { db in
            try exec(
                db: db,
                sql: """
                INSERT INTO tracks (
                    id, file_path, file_hash, title, artist, bpm, musical_key, energy_level,
                    energy_confidence, duration, preview_start, needs_review, review_notes,
                    has_overrides, analysis_version
                ) VALUES (
                    \(id), '\(filePath)', 'hash-\(id)', '\(title)', '\(artist)', \(bpm), '\(key)', \(energy),
                    1.0, \(duration), 0.0, \(needsReview ? 1 : 0), '\(reviewNotes)', \(hasOverrides ? 1 : 0), \(analysisVersion)
                )
                """
            )
        }
    }

    private func seedSet(dbURL: URL, id: Int, name: String, description: String, duration: Int) throws {
        try withSQLiteConnection(to: dbURL) { db in
            try exec(
                db: db,
                sql: """
                INSERT INTO sets (id, name, description, target_duration)
                VALUES (\(id), '\(name)', '\(description)', \(duration))
                """
            )
        }
    }

    private func seedSetTrack(dbURL: URL, setID: Int, trackID: Int, position: Int, score: Double) throws {
        try withSQLiteConnection(to: dbURL) { db in
            try exec(
                db: db,
                sql: """
                INSERT INTO set_tracks (set_id, track_id, position, transition_score)
                VALUES (\(setID), \(trackID), \(position), \(score))
                """
            )
        }
    }

    private func seedGap(dbURL: URL, setID: Int, position: Int) throws {
        try withSQLiteConnection(to: dbURL) { db in
            try exec(
                db: db,
                sql: """
                INSERT INTO gaps (set_id, position, suggested_bpm, suggested_key, suggested_energy, suggested_vibe)
                VALUES (\(setID), \(position), 128.0, '8A', 0.6, 'bridge track')
                """
            )
        }
    }

    private func seedOverride(dbURL: URL, filePath: String, bpm: Double, key: String, energy: Double) throws {
        try withSQLiteConnection(to: dbURL) { db in
            try exec(
                db: db,
                sql: """
                INSERT INTO track_overrides (file_path, bpm, musical_key, energy_level, updated_at)
                VALUES ('\(filePath)', \(bpm), '\(key)', \(energy), CURRENT_TIMESTAMP)
                """
            )
        }
    }

    private func countRows(dbURL: URL, table: String) throws -> Int {
        try withSQLiteConnection(to: dbURL) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(db)
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func withSQLiteConnection<T>(to url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            if let db {
                defer { sqlite3_close(db) }
                throw sqliteError(db)
            }
            throw NSError(domain: "DeepCrateMacTests", code: 1)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func exec(db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
    }

    private func sqliteError(_ db: OpaquePointer) -> NSError {
        NSError(
            domain: "DeepCrateMacTests",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }
}
