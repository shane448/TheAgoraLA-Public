import SwiftUI
import Foundation

/// One episode picked while browsing: its show's feed plus the GUID that
/// identifies it inside that feed.
struct PodcastSearchSelection: Identifiable, Hashable {
    let feedURL: URL
    let guid: String?
    let title: String

    var id: String { "\(feedURL.absoluteString)#\(guid ?? title)" }
}

/// Browse Apple's public podcast catalog without leaving the app. Picking an
/// episode hands its feed and GUID back to the caller, which then travels the
/// same import path a pasted link does.
struct PodcastSearchView: View {
    enum SelectionMode {
        /// Tapping an episode picks it and closes the sheet.
        case single
        /// Episodes accumulate until the caller's list is committed.
        case multiple
    }

    var mode: SelectionMode = .single
    /// Receives one episode in `.single` mode, or the whole batch in `.multiple`.
    let onSelect: ([PodcastSearchSelection]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var shows: [PodcastCatalogShow] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage = ""
    @State private var searchTask: Task<Void, Never>?

    private let service = PodcastImportService()

    var body: some View {
        NavigationStack {
            ZStack {
                AgoraTheme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Browse Podcasts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                AgoraCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Search")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        TextField("Show name", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { runSearch() }
                            .agoraFieldStyle()

                        Text("Find any show with a public feed, whichever app you normally listen in.")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Button("Search") { runSearch() }
                            .buttonStyle(AgoraPillButtonStyle())
                            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching the catalog...")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    .padding(.horizontal, 4)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.accent)
                        .padding(.horizontal, 4)
                }

                if !isSearching, hasSearched, shows.isEmpty, errorMessage.isEmpty {
                    Text("No shows matched that search. Try the show's exact name, or paste a link instead.")
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                        .padding(.horizontal, 4)
                }

                ForEach(shows) { show in
                    NavigationLink {
                        PodcastEpisodePickerView(show: show, mode: mode) { picks in
                            onSelect(picks)
                            dismiss()
                        }
                    } label: {
                        AgoraCard {
                            HStack(spacing: 12) {
                                PodcastArtwork(url: show.artworkURL, size: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(show.title)
                                        .font(AgoraTheme.cardTitleFont)
                                        .foregroundColor(AgoraTheme.ink)
                                        .multilineTextAlignment(.leading)
                                    if let author = show.author {
                                        Text(author)
                                            .font(AgoraTheme.tagFont)
                                            .foregroundColor(AgoraTheme.inkMuted)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(AgoraTheme.inkMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private func runSearch() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        errorMessage = ""
        isSearching = true
        searchTask = Task {
            defer { isSearching = false }
            do {
                let results = try await service.searchShows(term: term)
                guard !Task.isCancelled else { return }
                shows = results
                hasSearched = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                shows = []
                hasSearched = true
                errorMessage = "The catalog could not be reached. Check your connection, or paste a link instead."
            }
        }
    }
}

/// The episode list for one browsed show.
private struct PodcastEpisodePickerView: View {
    let show: PodcastCatalogShow
    let mode: PodcastSearchView.SelectionMode
    let onSelect: ([PodcastSearchSelection]) -> Void

    @State private var episodes: [PodcastCatalogEpisode] = []
    @State private var isLoading = true
    @State private var errorMessage = ""
    @State private var pickedIDs: Set<String> = []

    private let service = PodcastImportService()

    var body: some View {
        ZStack {
            AgoraTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading episodes...")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }
                        .padding(.horizontal, 4)
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                            .padding(.horizontal, 4)
                    }

                    ForEach(episodes) { episode in
                        Button {
                            tap(episode)
                        } label: {
                            AgoraCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top, spacing: 8) {
                                        if mode == .multiple {
                                            Image(systemName: pickedIDs.contains(episode.id)
                                                ? "checkmark.circle.fill"
                                                : "circle")
                                                .font(.system(size: 17))
                                                .foregroundColor(pickedIDs.contains(episode.id)
                                                    ? AgoraTheme.accent
                                                    : AgoraTheme.inkMuted)
                                        }
                                        Text(episode.title)
                                            .font(AgoraTheme.cardTitleFont)
                                            .foregroundColor(AgoraTheme.ink)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    if let detail = episodeDetail(episode) {
                                        Text(detail)
                                            .font(AgoraTheme.tagFont)
                                            .foregroundColor(AgoraTheme.inkMuted)
                                    }
                                    if let summary = episode.summary {
                                        Text(summary)
                                            .font(AgoraTheme.bodyFont)
                                            .foregroundColor(AgoraTheme.inkMuted)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom) {
                if mode == .multiple, !pickedIDs.isEmpty {
                    Button("Add \(pickedIDs.count) to Backlog") { commitSelection() }
                        .buttonStyle(AgoraPillButtonStyle())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let feedURL = show.feedURL else {
                errorMessage = "This show does not publish a feed Agora can read. Paste an episode link instead."
                isLoading = false
                return
            }
            do {
                episodes = try await service.episodes(inFeed: feedURL)
                if episodes.isEmpty {
                    errorMessage = "No playable episodes were found in this show's feed. Paste an episode link instead."
                }
            } catch {
                errorMessage = "Those episodes could not be loaded. Check your connection, or paste an episode link instead."
            }
            isLoading = false
        }
    }

    private func tap(_ episode: PodcastCatalogEpisode) {
        guard show.feedURL != nil else { return }
        switch mode {
        case .single:
            if let selection = selection(for: episode) { onSelect([selection]) }
        case .multiple:
            if pickedIDs.contains(episode.id) {
                pickedIDs.remove(episode.id)
            } else {
                pickedIDs.insert(episode.id)
            }
        }
    }

    private func commitSelection() {
        // Committed in list order so the backlog queues them as the feed lists them.
        let picks = episodes.filter { pickedIDs.contains($0.id) }.compactMap(selection(for:))
        guard !picks.isEmpty else { return }
        onSelect(picks)
    }

    private func selection(for episode: PodcastCatalogEpisode) -> PodcastSearchSelection? {
        guard let feedURL = show.feedURL else { return nil }
        return PodcastSearchSelection(feedURL: feedURL, guid: episode.guid, title: episode.title)
    }

    private func episodeDetail(_ episode: PodcastCatalogEpisode) -> String? {
        var parts: [String] = []
        if let date = episode.releaseDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let seconds = episode.durationSeconds, seconds >= 60 {
            parts.append("\(Int(seconds / 60)) min")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct PodcastArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                AgoraTheme.tagBackground
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
