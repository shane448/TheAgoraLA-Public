import Foundation

@MainActor
final class EpisodeStore: ObservableObject {
    @Published var episode: Episode
    @Published private(set) var savedEpisodes: [Episode]
    @Published private(set) var isLibraryLoaded = false

    private let storageKey = "TheAgoraLA.Episode.Data"
    private static let retiredDemoID = UUID(uuidString: "A60DD4CF-8B21-4A03-9D36-E43EC6C351AE")!
    private var libraryLoadTask: Task<[Episode], Never>?
    private var promptPersistenceTask: Task<Void, Never>?

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

    private static var libraryStorageURL: URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("episode-library.json")
    }

    init() {
        let loadedEpisode: Episode
        if let url = Self.storageURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            loadedEpisode = saved
        } else if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Episode.self, from: data) {
            loadedEpisode = saved
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            loadedEpisode = MockEpisodeProvider.sample
        }

        episode = loadedEpisode
        savedEpisodes = []

        if episode.id == Self.retiredDemoID {
            episode = MockEpisodeProvider.sample
        }
    }

    func loadLibraryIfNeeded() async {
        guard !isLibraryLoaded else { return }

        let task: Task<[Episode], Never>
        if let libraryLoadTask {
            task = libraryLoadTask
        } else {
            let url = Self.libraryStorageURL
            task = Task.detached(priority: .userInitiated) {
                guard let url,
                      let data = try? Data(contentsOf: url),
                      let episodes = try? JSONDecoder().decode([Episode].self, from: data) else {
                    return []
                }
                return episodes
            }
            libraryLoadTask = task
        }

        let loadedEpisodes = await task.value
        guard !isLibraryLoaded else { return }
        savedEpisodes = loadedEpisodes
        isLibraryLoaded = true
        libraryLoadTask = nil
        syncActiveEpisodeIntoLibrary()
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persistPromptsAfterTyping()
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
            summary: sourceChanged ? nil : episode.summary,
            durationSeconds: sourceChanged ? nil : episode.durationSeconds,
            artworkURL: sourceChanged ? nil : episode.artworkURL
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
            summary: episode.summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
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
        summary: String?,
        durationSeconds: Double?,
        artworkURL: URL? = nil
    ) {
        let sourceChanged = !matchesResolvedEpisode(
            audioURL: audioURL,
            feedURL: feedURL,
            episodeGUID: episodeGUID
        )
        episode = Episode(
            id: sourceChanged ? UUID() : episode.id,
            title: title,
            audioURL: audioURL,
            sourceURL: sourceURL,
            prompts: sourceChanged ? [] : episode.prompts,
            feedURL: sourceChanged ? feedURL : (feedURL ?? episode.feedURL),
            episodeGUID: sourceChanged ? episodeGUID : (episodeGUID ?? episode.episodeGUID),
            transcript: transcript,
            summary: summary,
            durationSeconds: sourceChanged ? durationSeconds : (durationSeconds ?? episode.durationSeconds),
            artworkURL: sourceChanged ? artworkURL : (artworkURL ?? episode.artworkURL)
        )
        persist()
    }

    func matchesResolvedEpisode(audioURL: URL, feedURL: URL?, episodeGUID: String?) -> Bool {
        let currentGUID = normalizedIdentifier(episode.episodeGUID)
        let importedGUID = normalizedIdentifier(episodeGUID)

        if let currentGUID, let importedGUID {
            guard currentGUID == importedGUID else { return false }
            if let currentFeed = episode.feedURL, let feedURL {
                return normalizedFeedURL(currentFeed) == normalizedFeedURL(feedURL)
            }
            return true
        }

        return episode.audioURL == audioURL
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
            summary: summary,
            durationSeconds: episode.durationSeconds,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func saveAnalysis(_ analysis: EpisodeAnalysisResult, expectedAudioURL: URL) throws {
        guard episode.audioURL == expectedAudioURL else {
            throw CloudAnalysisError.service("This analysis belongs to a different episode. Your current podcast has not been changed.")
        }
        let updated = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: analysis.transcript,
            summary: analysis.summary,
            durationSeconds: analysis.duration,
            artworkURL: episode.artworkURL
        )
        guard let url = Self.storageURL else {
            throw CloudAnalysisError.service("Episode storage is unavailable. Please try saving again.")
        }
        let data = try JSONEncoder().encode(updated)
        try data.write(to: url, options: .atomic)
        episode = updated
        syncActiveEpisodeIntoLibrary()
        persistLibrary()
    }

    func updateDuration(_ duration: Double) {
        guard duration.isFinite, duration > 10,
              abs((episode.durationSeconds ?? 0) - duration) > 1 else { return }
        episode = Episode(
            id: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            sourceURL: episode.sourceURL,
            prompts: episode.prompts,
            feedURL: episode.feedURL,
            episodeGUID: episode.episodeGUID,
            transcript: episode.transcript,
            summary: episode.summary,
            durationSeconds: duration,
            artworkURL: episode.artworkURL
        )
        persist()
    }

    func saveEpisode(_ savedEpisode: Episode, makeActive: Bool = false) throws {
        let replacesActiveEpisode = savedEpisode.id == episode.id
        var updatedLibrary = savedEpisodes
        if let index = updatedLibrary.firstIndex(where: { $0.id == savedEpisode.id }) {
            updatedLibrary[index] = savedEpisode
        } else {
            updatedLibrary.insert(savedEpisode, at: 0)
        }
        if isLibraryLoaded, let libraryURL = Self.libraryStorageURL {
            try JSONEncoder().encode(updatedLibrary).write(to: libraryURL, options: .atomic)
        }
        if makeActive || replacesActiveEpisode {
            guard let storageURL = Self.storageURL else {
                throw CloudAnalysisError.service("Episode storage is unavailable. Please try saving again.")
            }
            try JSONEncoder().encode(savedEpisode).write(to: storageURL, options: .atomic)
            episode = savedEpisode
        }
        savedEpisodes = updatedLibrary
    }

    @discardableResult
    func selectEpisode(id: UUID) -> Bool {
        guard let selected = savedEpisodes.first(where: { $0.id == id }) else { return false }
        episode = selected
        persist()
        return true
    }

    func deleteSavedEpisode(id: UUID) {
        guard id != episode.id else { return }
        savedEpisodes.removeAll { $0.id == id }
        persistLibrary()
    }

    private func persist() {
        guard let url = Self.storageURL, let data = try? JSONEncoder().encode(episode) else { return }
        try? data.write(to: url, options: .atomic)
        syncActiveEpisodeIntoLibrary()
        persistLibrary()
    }

    private func persistPromptsAfterTyping() {
        promptPersistenceTask?.cancel()
        promptPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func syncActiveEpisodeIntoLibrary() {
        guard isLibraryLoaded, !episode.audioURL.isFileURL else { return }
        upsertSavedEpisode(episode)
    }

    private func upsertSavedEpisode(_ savedEpisode: Episode) {
        if let index = savedEpisodes.firstIndex(where: { $0.id == savedEpisode.id }) {
            savedEpisodes[index] = savedEpisode
        } else {
            savedEpisodes.insert(savedEpisode, at: 0)
        }
    }

    private func persistLibrary() {
        guard isLibraryLoaded,
              let url = Self.libraryStorageURL,
              let data = try? JSONEncoder().encode(savedEpisodes) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedFeedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        components.query = nil
        return components.url ?? url
    }
}
