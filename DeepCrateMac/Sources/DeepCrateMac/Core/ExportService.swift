import Foundation

enum ExportServiceError: LocalizedError {
    case unsupportedFormat(String)
    case emptySet(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported export format: \(format)"
        case .emptySet(let name):
            return "Set has no tracks to export: \(name)"
        }
    }
}

struct ExportService {
    func exportSet(name: String, format: String, outputPath: String) throws -> String {
        let normalizedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tracks = try LocalDatabase.shared.tracksForSet(name: name)
        guard !tracks.isEmpty else {
            throw ExportServiceError.emptySet(name)
        }

        let outputURL: URL
        let contents: String

        switch normalizedFormat {
        case "m3u":
            outputURL = resolvedOutputURL(name: name, format: normalizedFormat, outputPath: outputPath)
            contents = renderM3U(setName: name, tracks: tracks)
        case "rekordbox", "xml":
            outputURL = resolvedOutputURL(name: name, format: "xml", outputPath: outputPath)
            contents = renderRekordboxXML(setName: name, tracks: tracks)
        default:
            throw ExportServiceError.unsupportedFormat(format)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL.path
    }

    private func renderM3U(setName: String, tracks: [Track]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(setName)"]
        for track in tracks {
            lines.append("#EXTINF:\(Int(track.duration)),\(playlistDisplayName(for: track))")
            lines.append(track.filePath)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderRekordboxXML(setName: String, tracks: [Track]) -> String {
        var lines: [String] = [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<DJ_PLAYLISTS Version="1.0.0">"#,
            #"  <PRODUCT Name="DeepCrate" Version="0.1.0"/>"#,
            #"  <COLLECTION Entries="\#(tracks.count)">"#
        ]

        for (index, track) in tracks.enumerated() {
            let fileURL = URL(fileURLWithPath: track.filePath).standardizedFileURL
            let path = fileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.path
            let location = "file://localhost" + path
            let title = xmlEscape(rekordboxTitle(for: track))
            let artist = xmlEscape(track.artist)
            let key = xmlEscape(track.key)
            let locationValue = xmlEscape(location)
            lines.append(
                #"    <TRACK TrackID="\#(index + 1)" Name="\#(title)" Artist="\#(artist)" TotalTime="\#(Int(track.duration))" AverageBpm="\#(String(format: "%.2f", track.bpm))" Tonality="\#(key)" Location="\#(locationValue)"/>"#
            )
        }

        lines.append("  </COLLECTION>")
        lines.append("  <PLAYLISTS>")
        lines.append(#"    <NODE Type="0" Name="ROOT" Count="1">"#)
        lines.append(
            #"      <NODE Type="1" Name="\#(xmlEscape(setName))" KeyType="0" Entries="\#(tracks.count)">"#
        )
        for index in tracks.indices {
            lines.append(#"        <TRACK Key="\#(index + 1)"/>"#)
        }
        lines.append("      </NODE>")
        lines.append("    </NODE>")
        lines.append("  </PLAYLISTS>")
        lines.append("</DJ_PLAYLISTS>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func resolvedOutputURL(name: String, format: String, outputPath: String) -> URL {
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "\(safeExportName(name)).\(format)"
        let rawPath = trimmed.isEmpty ? fallback : (trimmed as NSString).expandingTildeInPath

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return cwd.appendingPathComponent(rawPath)
    }

    private func safeExportName(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
    }

    private func playlistDisplayName(for track: Track) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty, !title.isEmpty {
            return "\(artist) - \(title)"
        }
        if !title.isEmpty {
            return title
        }
        let filePath = track.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if filePath.isEmpty {
            return "Unknown"
        }
        return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    }

    private func rekordboxTitle(for track: Track) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        let filePath = track.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if filePath.isEmpty {
            return "Unknown Track"
        }
        return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
