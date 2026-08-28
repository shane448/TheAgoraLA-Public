import Foundation

@MainActor
final class EpisodeStore: ObservableObject {
    @Published var episode: Episode

    private let storageKey = "TheAgoraLA.Episode.Data"

    private static var storageURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = applicationSupport.appendingPathComponent("TheAgoraLA", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("episode.json")
    }

    init() {
        if let url = Self.storageURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            episode = saved
        } else if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            episode = saved
            persist()
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            episode = MockEpisodeProvider.sample
        }
    }

    func updateEpisode(_ updated: Episode) {
        episode = updated
        persist()
    }

    func addPrompt(_ prompt: Prompt) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: (episode.prompts + [prompt]).sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary
        )
        persist()
    }

    func updatePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.map { existing in
            existing.id == prompt.id ? prompt : existing
        }.sorted { $0.timestampSeconds < $1.timestampSeconds }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary
        )
        persist()
    }

    func deletePrompt(_ prompt: Prompt) {
        let updatedPrompts = episode.prompts.filter { $0.id != prompt.id }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: updatedPrompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary
        )
        persist()
    }

    func updateAudioURL(_ url: URL) {
        let sourceChanged = episode.audioURL != url
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: url,
            sourceURL: sourceChanged ? url : episode.sourceURL,
            prompts: sourceChanged ? [] : episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: sourceChanged ? nil : episode.transcript,
            summary: sourceChanged ? nil : episode.summary
        )
        persist()
    }

    func updateTitle(_ title: String) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary
        )
        persist()
    }
    
    func updateTranscript(_ transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript,
            summary: episode.summary
        )
        persist()
    }
    
    func updateTitleAndTranscript(title: String, transcript: String?) {
        episode = Episode(
            id: episode.id,
            title: title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: transcript,
            summary: episode.summary
        )
        persist()
    }
    
    func replacePrompts(_ newPrompts: [Prompt]) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: newPrompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary
        )
        persist()
    }

    func importEpisode(
        title: String,
        audioURL: URL,
        sourceURL: URL,
        feedURL: URL?,
        episodeGUID: String?,
        transcript: String?,
        summary: String?
    ) {
        let sourceChanged = episode.sourceURL != sourceURL
            || (episode.sourceURL == nil && episode.audioURL != audioURL)
        episode = Episode(
            id: sourceChanged ? UUID() : episode.id,
            title: title,
            audioURL: audioURL,
            sourceURL: sourceURL,
            prompts: sourceChanged ? [] : episode.prompts,
            feedURL: sourceChanged ? feedURL : (feedURL ?? episode.feedURL),
            episodeGUID: sourceChanged ? episodeGUID : (episodeGUID ?? episode.episodeGUID),
            transcript: transcript,
            summary: summary
        )
        persist()
    }

    func updateSummary(_ summary: String?) {
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: summary
        )
        persist()
    }

    func loadReviewDemo() {
        episode = MockEpisodeProvider.reviewDemo
        persist()
    }

    private func persist() {
        guard let url = Self.storageURL, let data = try? JSONEncoder().encode(episode) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
