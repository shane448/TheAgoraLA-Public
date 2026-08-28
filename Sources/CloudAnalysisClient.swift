import Foundation

enum CloudAnalysisError: LocalizedError {
    case notConfigured
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud analysis has not been configured for this build."
        case .invalidResponse:
            return "The cloud analysis service returned an unreadable response."
        case .service(let message):
            return message
        }
    }
}

struct PendingCloudAnalysis: Codable {
    let jobID: UUID
    let expectedAudioURL: URL
}

struct CloudAnalysisClient {
    private static let installationKey = "TheAgoraLA.Cloud.InstallationID"
    private static let sessionKey = "TheAgoraLA.Cloud.SessionToken"
    private static let pendingKey = "TheAgoraLA.Cloud.PendingAnalysis"

    static var isConfigured: Bool { baseURL != nil }

    static var pendingAnalysis: PendingCloudAnalysis? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingCloudAnalysis.self, from: data)
    }

    func submitAndWait(
        title: String,
        audioURL: URL,
        transcript: String?,
        duration: Double?,
        promptCount: Int,
        model: String,
        providerAPIKey: String,
        progress: @escaping (String) -> Void
    ) async throws -> (EpisodeAnalysisResult, URL) {
        progress("Securely sending the episode to cloud analysis...")
        var body: [String: Any] = [
            "title": title,
            "audio_url": audioURL.absoluteString,
            "prompt_count": min(max(promptCount, 3), 12),
            "model": model,
            "provider_api_key": providerAPIKey,
        ]
        if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["transcript"] = transcript
        }
        if let duration, duration > 10 { body["duration"] = duration }
        let data = try await authorizedRequest(path: "v1/episode-jobs", method: "POST", body: body)
        let job = try JSONDecoder().decode(JobEnvelope.self, from: data)
        let pending = PendingCloudAnalysis(jobID: job.id, expectedAudioURL: audioURL)
        Self.savePending(pending)
        progress("Cloud analysis is running. You can safely leave the app and return later.")
        return (try await waitForCompletion(pending, progress: progress), audioURL)
    }

    func resumePending(progress: @escaping (String) -> Void) async throws -> (EpisodeAnalysisResult, URL)? {
        guard let pending = Self.pendingAnalysis else { return nil }
        progress("Reconnecting to your cloud analysis...")
        return (try await waitForCompletion(pending, progress: progress), pending.expectedAudioURL)
    }

    private func waitForCompletion(
        _ pending: PendingCloudAnalysis,
        progress: @escaping (String) -> Void
    ) async throws -> EpisodeAnalysisResult {
        while true {
            try Task.checkCancellation()
            let data = try await authorizedRequest(path: "v1/episode-jobs/\(pending.jobID.uuidString)", method: "GET")
            let job = try JSONDecoder().decode(JobEnvelope.self, from: data)
            switch job.status {
            case "complete":
                guard let result = job.result else { throw CloudAnalysisError.invalidResponse }
                Self.clearPending()
                progress("Cloud analysis complete.")
                return result.episodeAnalysis
            case "failed":
                Self.clearPending()
                throw CloudAnalysisError.service(job.error ?? "Cloud analysis could not finish this episode.")
            case "processing":
                progress("Transcribing and analyzing the complete episode in the cloud. You can leave the app.")
            default:
                progress("Your episode is queued in the cloud. You can leave the app.")
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func authorizedRequest(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var token = try await sessionToken()
        for attempt in 0...1 {
            var request = try makeRequest(path: path, method: method, body: body)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudAnalysisError.invalidResponse }
            if http.statusCode == 401, attempt == 0 {
                UserDefaults.standard.removeObject(forKey: Self.sessionKey)
                token = try await sessionToken()
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw CloudAnalysisError.service(serviceMessage(from: data) ?? "Cloud analysis is temporarily unavailable.")
            }
            return data
        }
        throw CloudAnalysisError.invalidResponse
    }

    private func sessionToken() async throws -> String {
        if let token = UserDefaults.standard.string(forKey: Self.sessionKey), !token.isEmpty { return token }
        let installationID: String
        if let saved = UserDefaults.standard.string(forKey: Self.installationKey), UUID(uuidString: saved) != nil {
            installationID = saved
        } else {
            installationID = UUID().uuidString
            UserDefaults.standard.set(installationID, forKey: Self.installationKey)
        }
        let request = try makeRequest(
            path: "v1/auth/device",
            method: "POST",
            body: ["installation_id": installationID]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let token = (try? JSONDecoder().decode(SessionEnvelope.self, from: data))?.token else {
            throw CloudAnalysisError.service(serviceMessage(from: data) ?? "The cloud session could not be started.")
        }
        UserDefaults.standard.set(token, forKey: Self.sessionKey)
        return token
    }

    private func makeRequest(path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let baseURL = Self.baseURL else { throw CloudAnalysisError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func savePending(_ pending: PendingCloudAnalysis) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: pendingKey)
    }

    private static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    private func serviceMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
    }
}

private struct SessionEnvelope: Decodable { let token: String }
private struct ErrorEnvelope: Decodable { let error: String }

private struct JobEnvelope: Decodable {
    let id: UUID
    let status: String
    let result: CloudEpisodeResult?
    let error: String?
}

private struct CloudEpisodeResult: Decodable {
    struct CloudPrompt: Decodable {
        let time: Double
        let question: String
        let expectedAnswer: String

        enum CodingKeys: String, CodingKey {
            case time, question
            case expectedAnswer = "expected_answer"
        }
    }

    let transcript: String
    let duration: Double
    let summary: String
    let prompts: [CloudPrompt]

    var episodeAnalysis: EpisodeAnalysisResult {
        EpisodeAnalysisResult(
            transcript: transcript,
            duration: duration,
            summary: summary,
            prompts: prompts.map {
                Prompt(id: UUID(), timestampSeconds: $0.time, question: $0.question, expectedAnswer: $0.expectedAnswer)
            }.sorted { $0.timestampSeconds < $1.timestampSeconds },
            recommendedPromptCount: prompts.count,
            contentDepthLabel: "Cloud analyzed"
        )
    }
}
