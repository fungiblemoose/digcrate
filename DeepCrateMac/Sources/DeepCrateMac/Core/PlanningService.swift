import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum LocalPlanningError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Apple Foundation Model is unavailable on this Mac."
        }
    }
}

struct GenreAvailability {
    let interpretedGenres: [String]
    let matchingTrackCount: Int
    let totalTrackCount: Int

    var warningMessage: String? {
        guard !interpretedGenres.isEmpty, totalTrackCount > 0 else { return nil }

        if matchingTrackCount == 0 {
            return "No \(interpretedGenres.joined(separator: ", ")) tracks found in library. Planner will fall back to best available tracks."
        }
        if matchingTrackCount < 6 {
            return "Only \(matchingTrackCount) matching \(interpretedGenres.joined(separator: ", ")) tracks found. Planner may blend in adjacent styles."
        }
        return nil
    }
}

struct LocalApplePlanner {
    private struct GenreProfile {
        let family: String
        let name: String
        let aliases: [String]
        let bpmRange: ClosedRange<Double>
        let relaxedRange: ClosedRange<Double>
    }

    private let genreProfiles: [GenreProfile] = [
        GenreProfile(
            family: "dnb",
            name: "drum and bass",
            aliases: ["dnb", "drum and bass", "drum & bass", "drum n bass", "drum'n'bass"],
            bpmRange: 170...175,
            relaxedRange: 166...178
        ),
        GenreProfile(
            family: "dnb",
            name: "liquid drum and bass",
            aliases: ["liquid dnb", "liquid drum and bass", "liquid", "rollers"],
            bpmRange: 172...175,
            relaxedRange: 170...177
        ),
        GenreProfile(
            family: "dnb",
            name: "jungle",
            aliases: ["jungle", "oldschool jungle", "amen"],
            bpmRange: 165...174,
            relaxedRange: 160...176
        ),
        GenreProfile(
            family: "dnb",
            name: "neurofunk",
            aliases: ["neurofunk", "neuro", "dark dnb"],
            bpmRange: 172...178,
            relaxedRange: 170...180
        ),
        GenreProfile(
            family: "house",
            name: "house",
            aliases: ["house", "club house", "classic house"],
            bpmRange: 120...130,
            relaxedRange: 118...132
        ),
        GenreProfile(
            family: "house",
            name: "deep house",
            aliases: ["deep house", "deep"],
            bpmRange: 118...124,
            relaxedRange: 116...126
        ),
        GenreProfile(
            family: "house",
            name: "tech house",
            aliases: ["tech house"],
            bpmRange: 124...130,
            relaxedRange: 122...132
        ),
        GenreProfile(
            family: "house",
            name: "progressive house",
            aliases: ["progressive house", "prog house"],
            bpmRange: 124...132,
            relaxedRange: 122...134
        ),
        GenreProfile(
            family: "house",
            name: "bass house",
            aliases: ["bass house", "uk bass house"],
            bpmRange: 126...132,
            relaxedRange: 124...134
        ),
        GenreProfile(
            family: "house",
            name: "melodic house",
            aliases: ["melodic house", "melodic house and techno", "melodic"],
            bpmRange: 118...126,
            relaxedRange: 116...130
        ),
        GenreProfile(
            family: "house",
            name: "afro house",
            aliases: ["afro house", "afrohouse"],
            bpmRange: 118...124,
            relaxedRange: 116...126
        ),
        GenreProfile(
            family: "house",
            name: "organic house",
            aliases: ["organic house", "downtempo house"],
            bpmRange: 112...122,
            relaxedRange: 108...124
        ),
        GenreProfile(
            family: "house",
            name: "tropical house",
            aliases: ["tropical house", "trop house"],
            bpmRange: 100...115,
            relaxedRange: 96...118
        ),
        GenreProfile(
            family: "techno",
            name: "techno",
            aliases: ["techno"],
            bpmRange: 128...142,
            relaxedRange: 126...145
        ),
        GenreProfile(
            family: "techno",
            name: "melodic techno",
            aliases: ["melodic techno"],
            bpmRange: 124...132,
            relaxedRange: 122...135
        ),
        GenreProfile(
            family: "techno",
            name: "hard techno",
            aliases: ["hard techno", "hardgroove", "hard groove"],
            bpmRange: 140...155,
            relaxedRange: 136...160
        ),
        GenreProfile(
            family: "trance",
            name: "trance",
            aliases: ["trance"],
            bpmRange: 132...140,
            relaxedRange: 130...145
        ),
        GenreProfile(
            family: "trance",
            name: "psytrance",
            aliases: ["psytrance", "psy trance"],
            bpmRange: 138...145,
            relaxedRange: 136...148
        ),
        GenreProfile(
            family: "garage",
            name: "uk garage",
            aliases: ["uk garage", "garage", "ukg", "2-step", "2 step"],
            bpmRange: 128...136,
            relaxedRange: 126...138
        ),
        GenreProfile(
            family: "bass",
            name: "dubstep",
            aliases: ["dubstep", "140", "deep dubstep"],
            bpmRange: 138...145,
            relaxedRange: 136...146
        ),
        GenreProfile(
            family: "bass",
            name: "trap",
            aliases: ["trap", "edm trap"],
            bpmRange: 130...150,
            relaxedRange: 120...155
        ),
        GenreProfile(
            family: "breaks",
            name: "breakbeat",
            aliases: ["breakbeat", "breaks", "nu skool breaks"],
            bpmRange: 125...140,
            relaxedRange: 122...145
        ),
        GenreProfile(
            family: "electro",
            name: "electro",
            aliases: ["electro", "electro house"],
            bpmRange: 125...138,
            relaxedRange: 122...142
        ),
        GenreProfile(
            family: "hard-dance",
            name: "hardstyle",
            aliases: ["hardstyle", "rawstyle", "hardbass", "hard bass"],
            bpmRange: 145...155,
            relaxedRange: 140...160
        ),
        GenreProfile(
            family: "hiphop",
            name: "hip hop",
            aliases: ["hip hop", "hip-hop", "rap"],
            bpmRange: 85...102,
            relaxedRange: 78...110
        ),
        GenreProfile(
            family: "disco",
            name: "disco",
            aliases: ["disco", "nu disco", "nudisco"],
            bpmRange: 110...124,
            relaxedRange: 106...128
        ),
    ]

    private let jargonExpansions: [String: String] = [
        "dnb": "drum and bass",
        "drum n bass": "drum and bass",
        "ukg": "uk garage",
        "prog house": "progressive house",
        "afro": "afro house",
        "afrohouse": "afro house",
        "rollers": "liquid drum and bass",
        "neuro": "neurofunk",
        "hardbass": "hardstyle",
        "hard bass": "hardstyle",
        "hardgroove": "hard techno",
        "trop house": "tropical house",
        "2-step": "uk garage",
        "2 step": "uk garage",
    ]

    func evaluateGenreAvailability(description: String, tracks: [Track]) -> GenreAvailability {
        let profiles = inferGenreProfiles(from: description)
        guard !profiles.isEmpty else {
            return GenreAvailability(
                interpretedGenres: [],
                matchingTrackCount: tracks.count,
                totalTrackCount: tracks.count
            )
        }

        let candidates = genreCandidateTracks(tracks, profiles: profiles)
        return GenreAvailability(
            interpretedGenres: uniqueProfileNames(profiles),
            matchingTrackCount: candidates.count,
            totalTrackCount: tracks.count
        )
    }

    func fallbackPlanTrackIDs(description: String, durationMinutes: Int, tracks: [Track]) -> [Int] {
        let profiles = inferGenreProfiles(from: description)
        let filtered = filterTracks(tracks, profiles: profiles)
        return fallbackSelection(
            durationMinutes: durationMinutes,
            tracks: filtered,
            description: description,
            profiles: profiles
        )
    }

    func normalizePlannedIDs(
        _ ids: [Int],
        description: String,
        durationMinutes: Int,
        tracks: [Track]
    ) -> [Int] {
        let targetCount = targetTrackCount(durationMinutes: durationMinutes)
        let profiles = inferGenreProfiles(from: description)
        let filtered = filterTracks(tracks, profiles: profiles)
        let fallback = fallbackSelection(
            durationMinutes: durationMinutes,
            tracks: filtered,
            description: description,
            profiles: profiles
        )
        let trackLookup = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })

        var valid: [Int] = []
        for id in ids where trackLookup[id] != nil {
            if !valid.contains(id) {
                valid.append(id)
            }
        }
        for fallbackID in fallback where !valid.contains(fallbackID) {
            valid.append(fallbackID)
            if valid.count >= targetCount {
                break
            }
        }

        let reordered = reorderForFlow(
            ids: valid,
            lookup: trackLookup,
            description: description,
            profiles: profiles
        )
        return Array(reordered.prefix(targetCount))
    }

    func planTrackIDs(description: String, durationMinutes: Int, tracks: [Track]) async throws -> [Int] {
        let targetCount = targetTrackCount(durationMinutes: durationMinutes)
        let profiles = inferGenreProfiles(from: description)
        let genreFiltered = filterTracks(tracks, profiles: profiles)
        let fallback = fallbackSelection(
            durationMinutes: durationMinutes,
            tracks: genreFiltered,
            description: description,
            profiles: profiles
        )
        let trackLookup = Dictionary(uniqueKeysWithValues: genreFiltered.map { ($0.id, $0) })

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.availability == .available else {
                throw LocalPlanningError.modelUnavailable
            }

            let catalog = genreFiltered.prefix(300).map { track in
                "\(track.id)|\(track.artist)|\(track.title)|\(Int(track.bpm))|\(track.key)|\(String(format: "%.2f", track.energy))"
            }.joined(separator: "\n")

            var genreGuidance = ""
            if !profiles.isEmpty {
                let profileNames = uniqueProfileNames(profiles).prefix(4).joined(separator: ", ")
                let lowBPM = Int(profiles.map(\.bpmRange.lowerBound).min() ?? 0)
                let highBPM = Int(profiles.map(\.bpmRange.upperBound).max() ?? 0)
                let jargonPairs = matchedJargonExpansions(description)
                let jargonLine: String
                if jargonPairs.isEmpty {
                    jargonLine = ""
                } else {
                    jargonLine = "\n- Resolved shorthand: \(jargonPairs.map { "\($0.0)->\($0.1)" }.joined(separator: ", "))"
                }
                genreGuidance = """
                Genre guidance:
                - Interpreted genres: \(profileNames)
                - Typical BPM zone: \(lowBPM)-\(highBPM)
                - Treat DJ jargon and subgenre shorthand as intentional user language.\(jargonLine)
                """
            }

            let prompt = """
            You are planning a DJ set. Return ONLY strict JSON in this format:
            {"track_ids":[1,2,3]}

            Rules:
            - Use only IDs from the catalog.
            - Preserve musical flow across BPM, key, and energy.
            - Prefer around \(targetCount) tracks.
            - No explanation, no markdown, only JSON.
            \(genreGuidance)

            User request:
            \(description)

            Catalog:
            \(catalog)
            """

            let session = LanguageModelSession(model: model)
            let response = try await session.respond(to: prompt)
            if let ids = parseIDs(from: response.content), !ids.isEmpty {
                var valid: [Int] = []
                for id in ids where trackLookup[id] != nil {
                    if !valid.contains(id) {
                        valid.append(id)
                    }
                }

                if !valid.isEmpty {
                    for fallbackID in fallback where !valid.contains(fallbackID) {
                        valid.append(fallbackID)
                        if valid.count >= targetCount {
                            break
                        }
                    }

                    let reordered = reorderForFlow(
                        ids: valid,
                        lookup: trackLookup,
                        description: description,
                        profiles: profiles
                    )
                    if !reordered.isEmpty {
                        return Array(reordered.prefix(targetCount))
                    }
                }
            }
        }
#endif

        return fallback
    }

    private func fallbackSelection(
        durationMinutes: Int,
        tracks: [Track],
        description: String,
        profiles: [GenreProfile]
    ) -> [Int] {
        guard !tracks.isEmpty else { return [] }
        let targetCount = targetTrackCount(durationMinutes: durationMinutes)

        let ranked = tracks.sorted { lhs, rhs in
            contextRelevance(lhs, profiles: profiles) > contextRelevance(rhs, profiles: profiles)
        }
        let shortlist = Array(ranked.prefix(max(targetCount * 2, targetCount)))
        let lookup = Dictionary(uniqueKeysWithValues: shortlist.map { ($0.id, $0) })
        return Array(
            reorderForFlow(
                ids: shortlist.map(\.id),
                lookup: lookup,
                description: description,
                profiles: profiles
            ).prefix(targetCount)
        )
    }

    private func parseIDs(from raw: String) -> [Int]? {
        let cleaned = stripCodeFences(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }

        if let direct = try? JSONDecoder().decode(TrackIDEnvelope.self, from: data) {
            return direct.trackIDs
        }

        guard
            let start = cleaned.firstIndex(of: "{"),
            let end = cleaned.lastIndex(of: "}")
        else {
            return nil
        }

        let snippet = String(cleaned[start...end])
        guard let snippetData = snippet.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TrackIDEnvelope.self, from: snippetData).trackIDs
    }

    private func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(of: "```json", with: "")
            trimmed = trimmed.replacingOccurrences(of: "```", with: "")
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func targetTrackCount(durationMinutes: Int) -> Int {
        max(6, min(24, durationMinutes / 5))
    }

    private func normalizeText(_ text: String) -> String {
        var normalized = text.lowercased().replacingOccurrences(of: "&", with: " and ")
        normalized = normalized.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsPhrase(_ normalizedText: String, _ normalizedPhrase: String) -> Bool {
        guard !normalizedText.isEmpty, !normalizedPhrase.isEmpty else { return false }
        return " \(normalizedText) ".contains(" \(normalizedPhrase) ")
    }

    private func matchedJargonExpansions(_ description: String) -> [(String, String)] {
        let normalized = normalizeText(description)
        var matches: [(String, String)] = []
        for (term, expansion) in jargonExpansions {
            if containsPhrase(normalized, normalizeText(term)) {
                matches.append((term, expansion))
            }
        }
        return matches
    }

    private func expandedDescription(_ description: String) -> String {
        let normalized = normalizeText(description)
        let expansions = matchedJargonExpansions(description)
        guard !expansions.isEmpty else { return normalized }
        let expandedTerms = expansions.map { normalizeText($0.1) }.joined(separator: " ")
        return "\(normalized) \(expandedTerms)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func profileTokens(_ profile: GenreProfile) -> [String] {
        var tokens = Set<String>([normalizeText(profile.name)])
        for alias in profile.aliases {
            let normalized = normalizeText(alias)
            if !normalized.isEmpty {
                tokens.insert(normalized)
            }
        }
        return Array(tokens)
    }

    private func profileMatchScore(_ expandedDescription: String, profile: GenreProfile) -> Double {
        var score = 0.0
        let profileName = normalizeText(profile.name)
        for token in profileTokens(profile) where containsPhrase(expandedDescription, token) {
            let words = max(1, token.split(separator: " ").count)
            score += 1.0 + min(0.6, Double(words) * 0.1)
            if token == profileName {
                score += 0.2
            }
        }
        return score
    }

    private func inferGenreProfiles(from description: String) -> [GenreProfile] {
        let expanded = expandedDescription(description)
        var scored: [(score: Double, specificity: Int, profile: GenreProfile)] = []
        for profile in genreProfiles {
            let score = profileMatchScore(expanded, profile: profile)
            if score <= 0 {
                continue
            }
            let specificity = profileTokens(profile)
                .map { max(1, $0.split(separator: " ").count) }
                .max() ?? 1
            scored.append((score: score, specificity: specificity, profile: profile))
        }

        guard !scored.isEmpty else { return [] }

        scored.sort {
            if $0.score == $1.score {
                return $0.specificity > $1.specificity
            }
            return $0.score > $1.score
        }

        let strongest = scored[0].score
        let threshold = max(1.0, strongest * 0.45)

        var picked: [GenreProfile] = []
        var seen = Set<String>()
        for item in scored where item.score >= threshold {
            if seen.contains(item.profile.name) {
                continue
            }
            seen.insert(item.profile.name)
            picked.append(item.profile)
            if picked.count >= 6 {
                break
            }
        }
        return picked
    }

    private func uniqueProfileNames(_ profiles: [GenreProfile]) -> [String] {
        var names: [String] = []
        for profile in profiles where !names.contains(profile.name) {
            names.append(profile.name)
        }
        return names
    }

    private func bpmMatchesRange(_ bpm: Double, range: ClosedRange<Double>) -> Bool {
        guard bpm > 0 else { return false }
        let candidates = [bpm, bpm * 2.0, bpm / 2.0]
        return candidates.contains { range.contains($0) }
    }

    private func bpmMatchesAnyRange(_ bpm: Double, ranges: [ClosedRange<Double>]) -> Bool {
        ranges.contains { bpmMatchesRange(bpm, range: $0) }
    }

    private func profileRanges(_ profiles: [GenreProfile], relaxed: Bool) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var seen = Set<String>()
        for profile in profiles {
            let range = relaxed ? profile.relaxedRange : profile.bpmRange
            let key = "\(range.lowerBound)-\(range.upperBound)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            ranges.append(range)
        }
        return ranges
    }

    private func filterTracks(_ tracks: [Track], profiles: [GenreProfile]) -> [Track] {
        guard !profiles.isEmpty else { return tracks }
        let candidates = genreCandidateTracks(tracks, profiles: profiles)
        return candidates.isEmpty ? tracks : candidates
    }

    private func genreCandidateTracks(_ tracks: [Track], profiles: [GenreProfile]) -> [Track] {
        let strictRanges = profileRanges(profiles, relaxed: false)
        let strict = tracks.filter { bpmMatchesAnyRange($0.bpm, ranges: strictRanges) }
        if strict.count >= 8 {
            return strict
        }
        let relaxedRanges = profileRanges(profiles, relaxed: true)
        let relaxed = tracks.filter { bpmMatchesAnyRange($0.bpm, ranges: relaxedRanges) }
        if relaxed.count >= 8 {
            return relaxed
        }
        return strict.isEmpty ? relaxed : strict
    }

    private func contextRelevance(_ track: Track, profiles: [GenreProfile]) -> Double {
        var score = 0.0
        if track.bpm > 0 { score += 0.2 }
        if !track.key.isEmpty { score += 0.2 }
        if track.duration > 90 { score += 0.1 }

        if !profiles.isEmpty {
            var best = 0.0
            for profile in profiles {
                let center = (profile.bpmRange.lowerBound + profile.bpmRange.upperBound) / 2.0
                let distances = [
                    abs(track.bpm - center),
                    abs(track.bpm * 2.0 - center),
                    abs((track.bpm / 2.0) - center),
                ]
                if let nearest = distances.min() {
                    best = max(best, max(0.0, 1.0 - (nearest / 25.0)))
                }
            }
            score += best
        }

        score += max(0.0, 1.0 - abs(track.energy - 0.62))
        return score
    }

    private func reorderForFlow(
        ids: [Int],
        lookup: [Int: Track],
        description: String,
        profiles: [GenreProfile]
    ) -> [Int] {
        var remaining: [Track] = ids.compactMap { lookup[$0] }
        guard !remaining.isEmpty else { return [] }
        if remaining.count <= 2 {
            return remaining.map(\.id)
        }

        let prefersLowStart = descriptionPrefersLowStart(description)
        let seed: Track
        if prefersLowStart {
            seed = remaining.min(by: { $0.energy < $1.energy }) ?? remaining[0]
        } else {
            seed = remaining.min(by: { abs($0.energy - 0.45) < abs($1.energy - 0.45) }) ?? remaining[0]
        }

        var ordered: [Track] = [seed]
        remaining.removeAll(where: { $0.id == seed.id })

        while !remaining.isEmpty {
            let previous = ordered[ordered.count - 1]
            let direction = expectedEnergyDirection(
                position: ordered.count,
                total: ids.count,
                description: description
            )
            let next = remaining.max { lhs, rhs in
                candidateFlowScore(lhs, previous: previous, direction: direction, profiles: profiles)
                    < candidateFlowScore(rhs, previous: previous, direction: direction, profiles: profiles)
            } ?? remaining[0]

            ordered.append(next)
            remaining.removeAll(where: { $0.id == next.id })
        }

        return ordered.map(\.id)
    }

    private func candidateFlowScore(
        _ candidate: Track,
        previous: Track,
        direction: String,
        profiles: [GenreProfile]
    ) -> Double {
        var score = transitionScore(previous, candidate, expectedDirection: direction)
        if profiles.contains(where: { bpmMatchesRange(candidate.bpm, range: $0.bpmRange) }) {
            score += 0.12
        }
        if !candidate.artist.isEmpty && !previous.artist.isEmpty && candidate.artist != previous.artist {
            score += 0.03
        }
        return score
    }

    private func descriptionPrefersLowStart(_ description: String) -> Bool {
        let lower = normalizeText(description)
        return ["start mellow", "start chill", "warmup", "opening", "open with"].contains(where: lower.contains)
    }

    private func descriptionHasPeak(_ description: String) -> Bool {
        let lower = normalizeText(description)
        return ["peak", "build", "climax", "lift", "drive"].contains(where: lower.contains)
    }

    private func descriptionHasCooldown(_ description: String) -> Bool {
        let lower = normalizeText(description)
        return ["cool down", "cooldown", "wind down", "close mellow", "comedown"].contains(where: lower.contains)
    }

    private func expectedEnergyDirection(position: Int, total: Int, description: String) -> String {
        guard total > 2 else { return "any" }
        let progress = Double(position) / Double(max(total - 1, 1))
        let hasPeak = descriptionHasPeak(description)
        let hasCooldown = descriptionHasCooldown(description)

        if hasPeak && hasCooldown {
            return progress < 0.65 ? "up" : "down"
        }
        if hasPeak {
            return progress < 0.75 ? "up" : "any"
        }
        if hasCooldown {
            return progress > 0.5 ? "down" : "any"
        }
        return "any"
    }

    private func transitionScore(_ a: Track, _ b: Track, expectedDirection: String) -> Double {
        let key = keyCompatibility(a.key, b.key)
        let bpm = bpmCompatibility(a.bpm, b.bpm)
        let energy = energyFlow(a.energy, b.energy, expectedDirection: expectedDirection)
        return (0.4 * key) + (0.35 * bpm) + (0.25 * energy)
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

    private func energyFlow(_ a: Double, _ b: Double, expectedDirection: String) -> Double {
        let diff = b - a
        let absDiff = abs(diff)
        var base: Double
        switch absDiff {
        case let x where x > 0.5: base = 0.2
        case let x where x > 0.3: base = 0.5
        case let x where x > 0.15: base = 0.7
        default: base = 0.9
        }

        if expectedDirection == "up" && diff > 0 {
            base = min(base + 0.1, 1.0)
        } else if expectedDirection == "up" && diff < -0.1 {
            base = max(base - 0.2, 0.0)
        } else if expectedDirection == "down" && diff < 0 {
            base = min(base + 0.1, 1.0)
        } else if expectedDirection == "down" && diff > 0.1 {
            base = max(base - 0.2, 0.0)
        }

        return base
    }

    private func keyCompatibility(_ lhs: String, _ rhs: String) -> Double {
        guard let a = parseCamelot(lhs), let b = parseCamelot(rhs) else { return 0.5 }

        if a.number == b.number && a.letter == b.letter {
            return 1.0
        }
        if a.number == b.number && a.letter != b.letter {
            return 0.8
        }
        if a.letter == b.letter {
            let distance = min(abs(a.number - b.number), 12 - abs(a.number - b.number))
            if distance == 1 {
                return 0.8
            }
            if distance == 2 {
                return 0.5
            }
        }
        return 0.2
    }

    private func parseCamelot(_ value: String) -> (number: Int, letter: Character)? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let letter = normalized.last, letter == "A" || letter == "B" else { return nil }
        guard let number = Int(normalized.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }
}

private struct TrackIDEnvelope: Decodable {
    let trackIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
    }
}
