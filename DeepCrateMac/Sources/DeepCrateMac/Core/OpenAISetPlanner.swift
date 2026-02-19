import Foundation

enum OpenAISetPlannerError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing."
        case .invalidResponse:
            return "OpenAI planner returned invalid data."
        case .apiError(let message):
            return message
        }
    }
}

struct OpenAISetPlanner {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func planTrackIDs(
        description: String,
        durationMinutes: Int,
        tracks: [Track],
        apiKey: String,
        model: String
    ) async throws -> [Int] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAISetPlannerError.missingAPIKey
        }

        let localPlanner = LocalApplePlanner()
        let fallback = localPlanner.fallbackPlanTrackIDs(
            description: description,
            durationMinutes: durationMinutes,
            tracks: tracks
        )

        let targetCount = max(6, min(24, durationMinutes / 5))
        let catalog = tracks.prefix(300).map { track in
            "\(track.id)|\(track.artist)|\(track.title)|\(Int(track.bpm))|\(track.key)|\(String(format: "%.2f", track.energy))"
        }.joined(separator: "\n")

        let prompt = """
        You are planning a DJ set. Return ONLY strict JSON in this format:
        {"track_ids":[1,2,3]}

        Rules:
        - Use only IDs from the catalog.
        - Preserve musical flow across BPM, key, and energy.
        - Prefer around \(targetCount) tracks.
        - No explanation, no markdown, only JSON.

        User request:
        \(description)

        Catalog:
        \(catalog)
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(
                model: model.isEmpty ? "gpt-4o-mini" : model,
                messages: [
                    .init(role: "system", content: "You are an expert DJ set planner. Output strict JSON only."),
                    .init(role: "user", content: prompt),
                ],
                temperature: 0.7,
                maxTokens: 1200
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAISetPlannerError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown API error"
            throw OpenAISetPlannerError.apiError("OpenAI API error (\(http.statusCode)): \(body)")
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let raw = decoded.choices.first?.message.content else {
            throw OpenAISetPlannerError.invalidResponse
        }

        let planned = parseIDs(from: raw) ?? []
        if planned.isEmpty {
            return fallback
        }
        let normalized = localPlanner.normalizePlannedIDs(
            planned,
            description: description,
            durationMinutes: durationMinutes,
            tracks: tracks
        )
        return normalized.isEmpty ? fallback : normalized
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
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }

    let choices: [Choice]
}

private struct TrackIDEnvelope: Decodable {
    let trackIDs: [Int]

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
    }
}
