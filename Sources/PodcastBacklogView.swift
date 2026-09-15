import SwiftUI
import Foundation

private enum PodcastBacklogStatus: String, Codable {
    case waiting
    case resolving
    case submitting
    case queued
    case processing
    case complete
    case failed

    var title: String {
        switch self {
        case .waiting: return "Ready to submit"
        case .resolving: return "Finding episode"
        case .submitting: return "Sending to cloud"
        case .queued: return "Queued"
        case .processing: return "Analyzing"
        case .complete: return "Ready to listen"
        case .failed: return "Needs attention"
        }
    }

    var isActive: Bool {
        [.resolving, .submitting, .queued, .processing].contains(self)
    }
}

private struct PodcastBacklogItem: Identifiable, Codable {
    let id: UUID
    let episodeID: UUID
    let sourceURL: URL
    var title: String?
    var audioURL: URL?
    var feedURL: URL?
    var episodeGUID: String?
    var publisherSummary: String?
    var transcriptURL: URL?
    var transcriptType: String?
    var durationSeconds: Double?
    var jobID: UUID?
    var status: PodcastBacklogStatus
    var errorMessage: String?
    let createdAt: Date

    var displayTitle: String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? (sourceURL.host ?? "Podcast episode") : cleaned
    }

    var transcriptSource: PodcastTranscriptSource? {
        transcriptURL.map { PodcastTranscriptSource(url: $0, type: transcriptType) }
    }
}

@MainActor
private final class PodcastBacklogStore: ObservableObject {
    @Published private(set) var items: [PodcastBacklogItem]
    @Published private(set) var isSubmitting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUsingDirectFallback = false
    @Published var notice = ""

    private static var storageURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport.appendingPathComponent("TheAgoraLA", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("podcast-backlog.json")
    }

    init() {
        if let url = Self.storageURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([PodcastBacklogItem].self, from: data) {
            items = saved.map { storedItem in
                var item = storedItem
                if item.errorMessage?.localizedCaseInsensitiveContains("application not found") == true {
                    item.errorMessage = CloudAnalysisError.backgroundServiceUnavailable
                }
                if item.status.isActive, item.jobID == nil {
                    item.status = .waiting
                    item.errorMessage = "The previous preparation was interrupted. This podcast is ready to try again."
                }
                return item
            }
        } else {
            items = []
        }
    }

    var hasActiveJobs: Bool { items.contains { $0.status.isActive } }
    var hasStartableItems: Bool { items.contains { $0.status == .waiting || $0.status == .failed } }
    var completedCount: Int { items.filter { $0.status == .complete }.count }

    @discardableResult
    func addLinks(from entries: [String]) -> Bool {
        let filledEntries = entries.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !filledEntries.isEmpty else {
            notice = "Paste at least one complete podcast link beginning with https://."
            return false
        }

        var urls: [URL] = []
        for (index, entry) in filledEntries {
            let detected = PodcastSourceParser.urls(in: entry)
            guard detected.count == 1 else {
                notice = detected.isEmpty
                    ? "Podcast \(index + 1) needs one complete podcast or RSS link."
                    : "Podcast \(index + 1) contains multiple links. Use one link in each podcast slot."
                return false
            }
            urls.append(detected[0])
        }

        var requested = Set<String>()
        let unique = urls.filter { requested.insert(normalizedURL($0)).inserted }
        var newURLs: [URL] = []
        var restoredCount = 0
        var waitingCount = 0
        var runningCount = 0
        var completeCount = 0

        for url in unique {
            let identity = normalizedURL(url)
            guard let index = items.firstIndex(where: { normalizedURL($0.sourceURL) == identity }) else {
                newURLs.append(url)
                continue
            }

            switch items[index].status {
            case .failed:
                items[index].status = .waiting
                items[index].jobID = nil
                items[index].errorMessage = nil
                restoredCount += 1
            case .waiting:
                waitingCount += 1
            case .resolving, .submitting, .queued, .processing:
                runningCount += 1
            case .complete:
                completeCount += 1
            }
        }

        let availableSlots = max(0, 10 - items.filter { $0.status != .complete }.count)
        let additions = newURLs.prefix(availableSlots).map { url in
            PodcastBacklogItem(
                id: UUID(),
                episodeID: UUID(),
                sourceURL: url,
                title: nil,
                audioURL: nil,
                feedURL: nil,
                episodeGUID: nil,
                publisherSummary: nil,
                transcriptURL: nil,
                transcriptType: nil,
                durationSeconds: nil,
                jobID: nil,
                status: .waiting,
                errorMessage: nil,
                createdAt: Date()
            )
        }
        items.append(contentsOf: additions)
        persist()
        if additions.count < newURLs.count {
            notice = "Added \(additions.count). Finish or remove queued items before adding more than 10 active episodes."
            return false
        } else if restoredCount > 0 {
            let addedText = additions.isEmpty
                ? ""
                : " and added \(additions.count) new podcast\(additions.count == 1 ? "" : "s")"
            notice = "Restored \(restoredCount) failed podcast\(restoredCount == 1 ? "" : "s")\(addedText). Tap Analyze Backlog to try again."
        } else if !additions.isEmpty {
            notice = "Added \(additions.count) podcast\(additions.count == 1 ? "" : "s") to the backlog."
        } else if runningCount > 0 {
            notice = "That podcast is already being analyzed in your backlog."
        } else if waitingCount > 0 {
            notice = "That podcast is already ready. Tap Analyze Backlog to begin."
        } else if completeCount > 0 {
            notice = "That podcast is already prepared and ready to listen to below."
        } else {
            notice = "Those podcasts are already in your backlog."
        }
        return true
    }

    func startAll(episodeStore: EpisodeStore) async {
        guard !isSubmitting else { return }
        guard CloudAnalysisClient.isConfigured else {
            notice = "Background analysis needs the Agora cloud service configured in this build."
            return
        }
        guard let providerKey = AIAccountStore.apiKey() else {
            notice = "Connect your AI account before starting the backlog."
            return
        }
        let ids = items.filter { $0.status == .waiting || $0.status == .failed }.map(\.id)
        guard !ids.isEmpty else {
            notice = hasActiveJobs ? "Your backlog is already running in the cloud." : "Add podcast links to begin."
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        notice = "Checking the background analysis service..."
        do {
            try await CloudAnalysisClient().verifyAvailability()
        } catch {
            isUsingDirectFallback = true
            await prepareDirectly(ids: ids, episodeStore: episodeStore)
            return
        }
        isUsingDirectFallback = false

        notice = "Preparing and submitting \(ids.count) podcast\(ids.count == 1 ? "" : "s")..."

        for start in stride(from: 0, to: ids.count, by: 3) {
            let end = min(start + 3, ids.count)
            let tasks = ids[start..<end].map { id in
                Task { await self.submit(id: id, providerKey: providerKey) }
            }
            for task in tasks { await task.value }
        }
        await refreshAll(episodeStore: episodeStore)
        let failures = items.filter { $0.status == .failed }.count
        notice = failures == 0
            ? "Backlog submitted. You can leave the app while the cloud finishes."
            : "The cloud accepted the available episodes. Review any item marked Needs attention."
    }

    func refreshAll(episodeStore: EpisodeStore) async {
        guard !isRefreshing, CloudAnalysisClient.isConfigured else { return }
        let pendingIDs = items.filter { $0.jobID != nil && ($0.status == .queued || $0.status == .processing) }.map(\.id)
        guard !pendingIDs.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for id in pendingIDs {
            guard let item = item(with: id), let jobID = item.jobID, let audioURL = item.audioURL else { continue }
            do {
                let snapshot = try await CloudAnalysisClient().status(
                    for: PendingCloudAnalysis(jobID: jobID, expectedAudioURL: audioURL)
                )
                switch snapshot.state {
                case .queued:
                    update(id) { $0.status = .queued }
                case .processing:
                    update(id) { $0.status = .processing }
                case .failed:
                    update(id) {
                        $0.status = .failed
                        $0.errorMessage = snapshot.errorMessage ?? "Cloud analysis could not finish this episode."
                    }
                case .complete:
                    guard let analysis = snapshot.analysis else {
                        throw CloudAnalysisError.invalidResponse
                    }
                    let completed = Episode(
                        id: item.episodeID,
                        title: item.displayTitle,
                        audioURL: audioURL,
                        sourceURL: item.sourceURL,
                        prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
                        feedURL: item.feedURL,
                        episodeGUID: item.episodeGUID,
                        transcript: analysis.transcript,
                        summary: analysis.summary
                    )
                    episodeStore.saveEpisode(completed)
                    update(id) {
                        $0.status = .complete
                        $0.errorMessage = nil
                    }
                }
            } catch {
                if let urlError = error as? URLError,
                   [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
                    continue
                }
                let message = error.localizedDescription
                if message == CloudAnalysisError.backgroundServiceUnavailable {
                    update(id) {
                        $0.status = .failed
                        $0.jobID = nil
                        $0.errorMessage = message
                    }
                    notice = message
                    continue
                }
                update(id) {
                    $0.errorMessage = "Status will refresh when the cloud is reachable. \(message)"
                }
            }
        }
    }

    func retry(_ id: UUID) {
        update(id) {
            $0.status = .waiting
            $0.jobID = nil
            $0.errorMessage = nil
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func submit(id: UUID, providerKey: String) async {
        guard let original = item(with: id) else { return }
        update(id) {
            $0.status = .resolving
            $0.errorMessage = nil
        }
        do {
            let imported = try await PodcastImportService().importMetadata(from: original.sourceURL)
            update(id) {
                $0.title = imported.title
                $0.audioURL = imported.audioURL
                $0.feedURL = imported.feedURL
                $0.episodeGUID = imported.episodeGUID
                $0.publisherSummary = imported.publisherSummary
                $0.transcriptURL = imported.transcriptSource?.url
                $0.transcriptType = imported.transcriptSource?.type
                $0.durationSeconds = imported.durationSeconds
                $0.status = .submitting
            }
            let duration = imported.durationSeconds
            let pending = try await CloudAnalysisClient().submit(
                title: imported.title,
                audioURL: imported.audioURL,
                transcript: nil,
                transcriptSource: imported.transcriptSource,
                duration: duration,
                promptCount: nil,
                model: AIAccountStore.selectedModelID(),
                providerAPIKey: providerKey
            )
            update(id) {
                $0.jobID = pending.jobID
                $0.status = .queued
                $0.errorMessage = nil
            }
        } catch {
            update(id) {
                $0.status = .failed
                let message = error.localizedDescription
                $0.errorMessage = message.localizedCaseInsensitiveContains("application not found")
                    ? CloudAnalysisError.backgroundServiceUnavailable
                    : message
            }
        }
    }

    private func prepareDirectly(ids: [UUID], episodeStore: EpisodeStore) async {
        await episodeStore.loadLibraryIfNeeded()
        for (offset, id) in ids.enumerated() {
            notice = "Cloud background processing is unavailable. Preparing podcast \(offset + 1) of \(ids.count) through your connected AI; keep Agora open."
            await prepareDirectly(id: id, episodeStore: episodeStore)
        }

        let completed = ids.filter { id in item(with: id)?.status == .complete }.count
        let failures = ids.count - completed
        if failures == 0 {
            notice = "Your backlog is ready. All \(completed) podcast\(completed == 1 ? " was" : "s were") prepared through your connected AI."
        } else if completed > 0 {
            notice = "Prepared \(completed) podcast\(completed == 1 ? "" : "s"). Review the \(failures) item\(failures == 1 ? "" : "s") marked Needs attention."
        } else {
            notice = "Direct preparation could not finish. Review the message under the first podcast, then tap Analyze Backlog to retry."
        }
    }

    private func prepareDirectly(id: UUID, episodeStore: EpisodeStore) async {
        guard let original = item(with: id) else { return }
        update(id) {
            $0.status = .resolving
            $0.jobID = nil
            $0.errorMessage = "Finding the episode and its published transcript..."
        }

        do {
            let imported: PodcastImportResult
            if let audioURL = original.audioURL {
                imported = PodcastImportResult(
                    title: original.displayTitle,
                    audioURL: audioURL,
                    feedURL: original.feedURL,
                    episodeGUID: original.episodeGUID,
                    publisherSummary: original.publisherSummary,
                    transcriptSource: original.transcriptSource,
                    durationSeconds: original.durationSeconds
                )
            } else {
                imported = try await PodcastImportService().importMetadata(from: original.sourceURL)
            }

            update(id) {
                $0.title = imported.title
                $0.audioURL = imported.audioURL
                $0.feedURL = imported.feedURL
                $0.episodeGUID = imported.episodeGUID
                $0.publisherSummary = imported.publisherSummary
                $0.transcriptURL = imported.transcriptSource?.url
                $0.transcriptType = imported.transcriptSource?.type
                $0.durationSeconds = imported.durationSeconds
                $0.status = .processing
                $0.errorMessage = "Reading the complete episode..."
            }

            var publishedTranscript: String?
            if let source = imported.transcriptSource {
                publishedTranscript = try? await PodcastImportService().downloadTranscript(from: source)
            }
            let analysis = try await AIService().analyzeEpisode(
                title: imported.title,
                audioURL: imported.audioURL,
                transcript: publishedTranscript,
                audioDuration: imported.durationSeconds,
                desiredCount: nil,
                progress: { status in
                    Task { @MainActor in
                        self.update(id) { $0.errorMessage = status }
                    }
                }
            )
            try Task.checkCancellation()
            let completedEpisode = Episode(
                id: original.episodeID,
                title: imported.title,
                audioURL: imported.audioURL,
                sourceURL: original.sourceURL,
                prompts: analysis.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds },
                feedURL: imported.feedURL,
                episodeGUID: imported.episodeGUID,
                transcript: analysis.transcript,
                summary: analysis.summary
            )
            episodeStore.saveEpisode(completedEpisode)
            update(id) {
                $0.status = .complete
                $0.errorMessage = nil
            }
        } catch {
            update(id) {
                $0.status = .failed
                $0.jobID = nil
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func item(with id: UUID) -> PodcastBacklogItem? {
        items.first { $0.id == id }
    }

    private func update(_ id: UUID, change: (inout PodcastBacklogItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items[index]
        change(&updated)
        items[index] = updated
        persist()
    }

    private func persist() {
        guard let url = Self.storageURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func normalizedURL(_ url: URL) -> String {
        PodcastSourceParser.identity(for: url)
    }
}

private struct PodcastLinkDraft: Identifiable {
    let id = UUID()
    var text = ""
}

struct PodcastBacklogView: View {
    @ObservedObject var episodeStore: EpisodeStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var aiAccount: AIAccountStore
    @StateObject private var backlog = PodcastBacklogStore()
    @State private var linkDrafts = [PodcastLinkDraft()]
    @State private var showAIAccount = false
    @FocusState private var focusedLinkID: UUID?

    var body: some View {
        ZStack {
            AgoraBackgroundView()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    introductionCard
                    addLinksCard
                    backlogControls

                    if backlog.items.isEmpty {
                        emptyCard
                    } else {
                        ForEach(backlog.items) { item in
                            PodcastBacklogRow(
                                item: item,
                                isSelected: episodeStore.episode.id == item.episodeID,
                                onUse: {
                                    Task {
                                        await episodeStore.loadLibraryIfNeeded()
                                        if episodeStore.selectEpisode(id: item.episodeID) { dismiss() }
                                    }
                                },
                                onRetry: { backlog.retry(item.id) },
                                onRemove: {
                                    Task {
                                        if item.status == .complete {
                                            await episodeStore.loadLibraryIfNeeded()
                                            episodeStore.deleteSavedEpisode(id: item.episodeID)
                                        }
                                        backlog.remove(item.id)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(16)
                .padding(.vertical, 8)
            }
        }
        .task {
            await episodeStore.loadLibraryIfNeeded()
            while !Task.isCancelled {
                await backlog.refreshAll(episodeStore: episodeStore)
                try? await Task.sleep(nanoseconds: backlog.hasActiveJobs ? 8_000_000_000 : 15_000_000_000)
            }
        }
        .sheet(isPresented: $showAIAccount) {
            AIAccountView()
                .environmentObject(aiAccount)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Podcast Backlog")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Prepare several episodes while you do something else.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(AgoraOutlineButtonStyle())
        }
    }

    private var introductionCard: some View {
        AgoraCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: backlog.isUsingDirectFallback ? "iphone.gen3" : "cloud.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(backlog.isUsingDirectFallback ? "Direct preparation is running" : "Cloud preparation continues")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Text(
                        backlog.isUsingDirectFallback
                            ? "Keep Agora open while each episode is prepared through your connected AI. Completed podcasts are saved immediately."
                            : "Once every item says Queued or Analyzing, you may close Agora. Return later and choose any completed episode."
                    )
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }
        }
    }

    private var addLinksCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Podcast Links")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Paste one episode, show, public RSS feed, or direct audio link into each slot. Copied share messages also work.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                ForEach(Array(linkDrafts.enumerated()), id: \.element.id) { index, draft in
                    let position = index + 1
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label("Podcast \(position)", systemImage: "waveform")
                                .font(AgoraTheme.tagFont.weight(.semibold))
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            if linkDrafts.count > 1 {
                                Button {
                                    removeDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove podcast \(position)")
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            TextField("Paste podcast link", text: draftTextBinding(for: draft.id), axis: .vertical)
                                .font(AgoraTheme.bodyFont)
                                .foregroundColor(AgoraTheme.ink)
                                .tint(AgoraTheme.accent)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(2...3)
                                .focused($focusedLinkID, equals: draft.id)

                            if !draft.text.isEmpty {
                                Button {
                                    clearDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(AgoraTheme.inkMuted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear podcast \(position) link")
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.88))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AgoraTheme.cardSurface.opacity(0.58))
                    )
                }

                if linkDrafts.count < 10 {
                    Button {
                        addDraft()
                    } label: {
                        Label("Add Another Podcast", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }

                Button("Add to Backlog") {
                    submitDrafts()
                }
                .buttonStyle(AgoraOutlineButtonStyle())
                .disabled(linkDrafts.allSatisfy {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            }
        }
    }

    private func addDraft() {
        guard linkDrafts.count < 10 else { return }
        let draft = PodcastLinkDraft()
        withAnimation(.easeInOut(duration: 0.2)) {
            linkDrafts.append(draft)
        }
        focusedLinkID = draft.id
    }

    private func draftTextBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                linkDrafts.first(where: { $0.id == id })?.text ?? ""
            },
            set: { newValue in
                guard let index = linkDrafts.firstIndex(where: { $0.id == id }) else { return }
                linkDrafts[index].text = newValue
            }
        )
    }

    private func clearDraft(id: UUID) {
        guard let index = linkDrafts.firstIndex(where: { $0.id == id }) else { return }
        linkDrafts[index].text = ""
    }

    private func submitDrafts() {
        let entries = linkDrafts.map(\.text)
        focusedLinkID = nil
        guard backlog.addLinks(from: entries) else { return }

        DispatchQueue.main.async {
            linkDrafts = [PodcastLinkDraft()]
        }
    }

    private func removeDraft(id: UUID) {
        guard linkDrafts.count > 1 else { return }
        if focusedLinkID == id { focusedLinkID = nil }
        withAnimation(.easeInOut(duration: 0.2)) {
            linkDrafts.removeAll { $0.id == id }
        }
    }

    private var backlogControls: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(backlog.completedCount) ready · \(backlog.items.count) total")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text(backlog.notice.isEmpty ? "The strongest final AI review is used for every episode." : backlog.notice)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    Spacer()
                    if backlog.isRefreshing { ProgressView() }
                }

                if !aiAccount.isConnected {
                    Button("Connect Your AI") { showAIAccount = true }
                        .buttonStyle(AgoraOutlineButtonStyle())
                }

                Button(backlog.hasActiveJobs ? "Add Remaining to Running Backlog" : "Analyze Backlog") {
                    if aiAccount.isConnected {
                        Task { await backlog.startAll(episodeStore: episodeStore) }
                    } else {
                        showAIAccount = true
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(backlog.isSubmitting || !backlog.hasStartableItems)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyCard: some View {
        AgoraCard {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                Text("Your backlog is empty")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Add several podcast links above, then start them with one button.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PodcastBacklogRow: View {
    let item: PodcastBacklogItem
    let isSelected: Bool
    let onUse: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text(item.status.title)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(item.status == .failed ? Color.red : AgoraTheme.accent)
                    }
                    Spacer()
                    if isSelected { AgoraTag(text: "Selected") }
                }

                Text(item.sourceURL.absoluteString)
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .lineLimit(2)

                if let error = item.errorMessage, !error.isEmpty {
                    AgoraExpandableText(
                        text: error,
                        collapsedLineLimit: 2,
                        expansionThreshold: 120,
                        font: AgoraTheme.tagFont,
                        color: AgoraTheme.inkMuted
                    )
                }

                HStack {
                    if item.status == .complete {
                        Button(isSelected ? "Currently Selected" : "Use This Episode", action: onUse)
                            .buttonStyle(AgoraPillButtonStyle())
                            .disabled(isSelected)
                    } else if item.status == .failed {
                        Button("Retry", action: onRetry)
                            .buttonStyle(AgoraOutlineButtonStyle())
                    }
                    Spacer()
                    if !item.status.isActive && !isSelected {
                        Button(role: .destructive, action: onRemove) {
                            Label("Remove", systemImage: "trash")
                        }
                        .font(AgoraTheme.buttonFont)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.status.isActive {
            ProgressView()
                .tint(AgoraTheme.accent)
        } else {
            Image(systemName: item.status == .complete ? "checkmark.circle.fill" : item.status == .failed ? "exclamationmark.triangle.fill" : "clock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(item.status == .failed ? .red : AgoraTheme.accent)
        }
    }
}
