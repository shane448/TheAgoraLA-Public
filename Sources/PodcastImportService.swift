import Foundation

struct PodcastTranscriptSource {
    let url: URL
    let type: String?
}

struct PodcastImportResult {
    let title: String
    let audioURL: URL
    let feedURL: URL?
    let episodeGUID: String?
    let publisherSummary: String?
    let transcriptSource: PodcastTranscriptSource?
    let durationSeconds: Double?
}

enum PodcastImportError: LocalizedError {
    case invalidURL
    case unsupportedLink
    case feedNotFound
    case episodeNotFound
    case invalidResponse
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Paste a valid HTTPS podcast, RSS feed, or audio URL."
        case .unsupportedLink:
            return "This service does not expose a public podcast feed. Try an Apple Podcasts link, RSS feed, or direct audio link."
        case .feedNotFound:
            return "The podcast feed could not be found."
        case .episodeNotFound:
            return "No playable episode was found in this podcast feed."
        case .invalidResponse:
            return "The podcast service returned an invalid response."
        case .transcriptUnavailable:
            return "The published transcript could not be downloaded."
        }
    }
}

struct PodcastImportService {
    func importMetadata(from sourceURL: URL) async throws -> PodcastImportResult {
        guard sourceURL.scheme?.lowercased() == "https", sourceURL.host != nil else {
            throw PodcastImportError.invalidURL
        }

        if sourceURL.host?.lowercased().contains("podcasts.apple.com") == true {
            return try await importApplePodcast(from: sourceURL)
        }

        if isLikelyAudioURL(sourceURL) {
            let decodedTitle = sourceURL.deletingPathExtension().lastPathComponent
                .removingPercentEncoding?
                .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = decodedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Imported Episode"
            return PodcastImportResult(
                title: title,
                audioURL: sourceURL,
                feedURL: nil,
                episodeGUID: nil,
                publisherSummary: nil,
                transcriptSource: nil,
                durationSeconds: nil
            )
        }

        if isKnownPodcastPlatform(sourceURL) {
            return try await resolvePodcastPage(sourceURL)
        }

        do {
            return try await importFeed(sourceURL, matching: nil)
        } catch {
            return try await resolvePodcastPage(sourceURL)
        }
    }

    func downloadTranscript(from source: PodcastTranscriptSource) async throws -> String {
        let data = try await downloadData(
            from: source.url,
            maximumBytes: 25_000_000,
            acceptedTypes: ["text/", "application/json", "application/octet-stream"]
        ).data
        let raw = String(data: data, encoding: .utf8) ?? ""
        let type = source.type?.lowercased() ?? ""

        if type.contains("json") {
            if let transcript = decodeTranscriptJSON(data), wordCount(transcript) >= 20 {
                return normalizeWhitespace(transcript)
            }
        }
        if type.contains("html") {
            let transcript = cleanHTML(raw)
            guard wordCount(transcript) >= 20 else { throw PodcastImportError.transcriptUnavailable }
            return transcript
        }
        if type.contains("vtt") || type.contains("srt") || raw.hasPrefix("WEBVTT") || raw.contains(" --> ") {
            let transcript = cleanCaptions(raw)
            guard wordCount(transcript) >= 20 else { throw PodcastImportError.transcriptUnavailable }
            return transcript
        }

        let transcript = normalizeWhitespace(raw)
        guard wordCount(transcript) >= 20 else { throw PodcastImportError.transcriptUnavailable }
        return transcript
    }

    private func importApplePodcast(from appleURL: URL) async throws -> PodcastImportResult {
        guard let showID = identifier(in: appleURL.absoluteString, pattern: "id(\\d+)") else {
            throw PodcastImportError.invalidURL
        }
        let episodeID = URLComponents(url: appleURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "i" })?
            .value

        async let feedURL = appleFeedURL(showID: showID)
        async let episodeMetadata = appleEpisodeMetadata(episodeID: episodeID)
        let (resolvedFeedURL, metadata) = try await (feedURL, episodeMetadata)
        return try await importFeed(resolvedFeedURL, matching: metadata)
    }

    private func importFeed(_ feedURL: URL, matching metadata: AppleEpisodeMetadata?) async throws -> PodcastImportResult {
        let response = try await downloadData(
            from: feedURL,
            maximumBytes: 15_000_000,
            acceptedTypes: ["application/rss+xml", "application/xml", "text/xml", "text/plain", "application/octet-stream"]
        )
        let items: [RSSImportItem]
        do {
            items = try RSSImportParser().parse(data: response.data)
        } catch {
            throw PodcastImportError.unsupportedLink
        }
        guard !items.isEmpty else { throw PodcastImportError.unsupportedLink }

        let item = match(items: items, metadata: metadata)
            ?? items.first(where: { $0.audioURL != nil })
        guard let item, let audioURL = item.audioURL else {
            throw PodcastImportError.episodeNotFound
        }

        let title = normalizeWhitespace(item.title ?? metadata?.title ?? "Imported Episode")
        let summary = usefulPublisherSummary(item.contentEncoded ?? item.summary)
        return PodcastImportResult(
            title: title.isEmpty ? "Imported Episode" : title,
            audioURL: audioURL,
            feedURL: response.finalURL,
            episodeGUID: item.guid,
            publisherSummary: summary,
            transcriptSource: item.transcriptURL.map { PodcastTranscriptSource(url: $0, type: item.transcriptType) },
            durationSeconds: parseDuration(item.duration)
        )
    }

    private func resolvePodcastPage(_ pageURL: URL) async throws -> PodcastImportResult {
        let metadata = try await platformMetadata(from: pageURL)

        if let feedURL = metadata.feedURL,
           let imported = try? await importFeed(
                feedURL,
                matching: AppleEpisodeMetadata(guid: nil, title: metadata.isEpisode ? metadata.title : nil)
           ) {
            return imported
        }
        if let audioURL = metadata.audioURL {
            return PodcastImportResult(
                title: metadata.title ?? "Imported Episode",
                audioURL: audioURL,
                feedURL: nil,
                episodeGUID: nil,
                publisherSummary: usefulPublisherSummary(metadata.summary),
                transcriptSource: nil,
                durationSeconds: nil
            )
        }
        return try await resolveFromAppleCatalog(metadata: metadata)
    }

    private func platformMetadata(from pageURL: URL) async throws -> PodcastPageMetadata {
        var oEmbedTitle: String?
        if pageURL.host?.lowercased().contains("spotify.com") == true,
           var components = URLComponents(string: "https://open.spotify.com/oembed") {
            components.queryItems = [URLQueryItem(name: "url", value: pageURL.absoluteString)]
            if let url = components.url,
               let response = try? await downloadData(
                from: url,
                maximumBytes: 1_000_000,
                acceptedTypes: ["application/json", "text/json", "text/plain"]
               ),
               let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                oEmbedTitle = object["title"] as? String
            }
        }

        let response = try await downloadData(
            from: pageURL,
            maximumBytes: 6_000_000,
            acceptedTypes: ["text/html", "application/xhtml+xml", "text/plain"]
        )
        let html = String(data: response.data, encoding: .utf8) ?? ""
        let discoveredTitle = firstHTMLValue(
            in: html,
            names: ["og:title", "twitter:title"]
        )
        let pageTitle = firstMatch(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>").map(cleanHTML)
        let summary = firstHTMLValue(in: html, names: ["og:description", "twitter:description", "description"])
        let audioValue = firstHTMLValue(in: html, names: ["og:audio", "og:audio:url", "twitter:player:stream"])
            ?? firstMatch(in: html, pattern: "<audio[^>]+src=[\\\"']([^\\\"']+)")
            ?? firstMatch(in: html, pattern: "\\\"contentUrl\\\"\\s*:\\s*\\\"([^\\\"]+)")
        let feedValue = firstMatch(
            in: html,
            pattern: "<link(?=[^>]+type=[\\\"']application/(?:rss\\+xml|atom\\+xml)[\\\"'])[^>]+href=[\\\"']([^\\\"']+)"
        )
        let title = cleanPlatformTitle(pageTitle ?? oEmbedTitle ?? discoveredTitle)
        let path = pageURL.path.lowercased()
        let host = pageURL.host?.lowercased() ?? ""
        let isEpisode = path.contains("/episode/") || path.contains("/episodes/") || path.contains("/e/")
            || host == "youtu.be" || path == "/watch"
        return PodcastPageMetadata(
            title: title,
            summary: summary.map(cleanHTML),
            feedURL: feedValue.flatMap { resolveURL($0, relativeTo: response.finalURL) },
            audioURL: audioValue.flatMap { resolveURL($0, relativeTo: response.finalURL) },
            isEpisode: isEpisode
        )
    }

    private func resolveFromAppleCatalog(metadata: PodcastPageMetadata) async throws -> PodcastImportResult {
        guard let title = metadata.title, !title.isEmpty else { throw PodcastImportError.feedNotFound }
        if metadata.isEpisode {
            let episodeResults = try await searchAppleCatalog(term: title, entity: "podcastEpisode")
            if let match = bestCatalogMatch(in: episodeResults, title: title),
               let audioValue = match.previewUrl,
               let audioURL = secureURL(from: audioValue) {
                if let feedValue = match.feedUrl,
                   let feedURL = secureURL(from: feedValue),
                   let imported = try? await importFeed(
                    feedURL,
                    matching: AppleEpisodeMetadata(guid: match.episodeGuid, title: match.trackName)
                   ) {
                    return imported
                }
                return PodcastImportResult(
                    title: normalizeWhitespace(match.trackName ?? title),
                    audioURL: audioURL,
                    feedURL: match.feedUrl.flatMap(secureURL),
                    episodeGUID: match.episodeGuid,
                    publisherSummary: usefulPublisherSummary(match.description ?? match.shortDescription ?? metadata.summary),
                    transcriptSource: nil,
                    durationSeconds: match.trackTimeMillis.map { $0 / 1_000 }
                )
            }
        }

        let showResults = try await searchAppleCatalog(term: title, entity: "podcast")
        guard let match = bestCatalogMatch(in: showResults, title: title),
              let feedValue = match.feedUrl,
              let feedURL = secureURL(from: feedValue) else {
            throw PodcastImportError.feedNotFound
        }
        return try await importFeed(feedURL, matching: nil)
    }

    private func searchAppleCatalog(term: String, entity: String) async throws -> [AppleLookupItem] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components?.url else { throw PodcastImportError.invalidURL }
        let data = try await downloadData(
            from: url,
            maximumBytes: 5_000_000,
            acceptedTypes: ["application/json", "text/json", "text/plain"]
        ).data
        return (try? JSONDecoder().decode(AppleLookupResponse.self, from: data).results) ?? []
    }

    private func bestCatalogMatch(in results: [AppleLookupItem], title: String) -> AppleLookupItem? {
        let normalizedTitle = normalizedKey(title)
        let target = catalogTokens(normalizedTitle)
        guard !target.isEmpty else { return results.first }
        let ranked = results.max { left, right in
            catalogScore(left, target: target) < catalogScore(right, target: target)
        }
        guard let ranked else { return nil }

        // One-word show names such as "Overthink" must match exactly. Without this
        // guard, Apple's fuzzy search can silently substitute a different podcast.
        if target.count == 1 {
            let exactValues = [ranked.trackName, ranked.collectionName]
                .compactMap { $0 }
                .map(normalizedKey)
            return exactValues.contains(normalizedTitle) ? ranked : nil
        }

        return catalogScore(ranked, target: target) >= 0.58 ? ranked : nil
    }

    private func catalogScore(_ item: AppleLookupItem, target: Set<String>) -> Double {
        let value = [item.trackName, item.collectionName].compactMap { $0 }.joined(separator: " ")
        let candidate = catalogTokens(value)
        guard !candidate.isEmpty else { return 0 }
        let intersection = target.intersection(candidate)
        let targetCoverage = Double(intersection.count) / Double(target.count)
        let jaccard = Double(intersection.count) / Double(target.union(candidate).count)
        return (targetCoverage * 0.75) + (jaccard * 0.25)
    }

    private func catalogTokens(_ value: String) -> Set<String> {
        let ignored: Set<String> = [
            "and", "for", "from", "official", "podcast", "show", "the", "with"
        ]
        return Set(
            normalizedKey(value)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 2 && !ignored.contains($0) }
        )
    }

    private func firstHTMLValue(in html: String, names: [String], fallbackPattern: String? = nil) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let patterns = [
                "<meta[^>]+(?:property|name)=[\\\"']\(escaped)[\\\"'][^>]+content=[\\\"']([^\\\"']+)",
                "<meta[^>]+content=[\\\"']([^\\\"']+)[\\\"'][^>]+(?:property|name)=[\\\"']\(escaped)[\\\"']",
            ]
            for pattern in patterns {
                if let value = firstMatch(in: html, pattern: pattern) { return cleanHTML(value) }
            }
        }
        return fallbackPattern.flatMap { firstMatch(in: html, pattern: $0) }.map(cleanHTML)
    }

    private func firstMatch(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func resolveURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return nil }
        return secureURL(from: url.absoluteString)
    }

    private func cleanPlatformTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = cleanHTML(value)
            .replacingOccurrences(of: "\\s*\\|\\s*Podcast\\s+on\\s+Spotify\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s*[|·-]\\s*(Spotify|Apple Podcasts|Pocket Casts|Overcast|Amazon Music|iHeart)(?:\\s*Podcast)?(?:\\s*on\\s*Spotify)?\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func isKnownPodcastPlatform(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return [
            "spotify.com", "pca.st", "pocketcasts.com", "overcast.fm", "castro.fm",
            "pod.link", "player.fm", "podbean.com", "iheart.com", "tunein.com",
            "music.amazon.com", "audacy.com", "youtube.com", "youtu.be", "music.youtube.com",
        ].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func appleFeedURL(showID: String) async throws -> URL {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(showID)") else {
            throw PodcastImportError.invalidURL
        }
        let data = try await downloadData(
            from: url,
            maximumBytes: 2_000_000,
            acceptedTypes: ["application/json", "text/json", "text/plain"]
        ).data
        let lookup = try JSONDecoder().decode(AppleLookupResponse.self, from: data)
        guard let value = lookup.results.first?.feedUrl, let feedURL = secureURL(from: value) else {
            throw PodcastImportError.feedNotFound
        }
        return feedURL
    }

    private func appleEpisodeMetadata(episodeID: String?) async throws -> AppleEpisodeMetadata? {
        guard let episodeID, Int(episodeID) != nil,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(episodeID)&entity=podcastEpisode") else {
            return nil
        }
        let data = try await downloadData(
            from: url,
            maximumBytes: 2_000_000,
            acceptedTypes: ["application/json", "text/json", "text/plain"]
        ).data
        let lookup = try JSONDecoder().decode(AppleLookupResponse.self, from: data)
        guard let match = lookup.results.first(where: { $0.wrapperType == "podcastEpisode" || $0.episodeGuid != nil }) else {
            return nil
        }
        return AppleEpisodeMetadata(guid: match.episodeGuid, title: match.trackName)
    }

    private func match(items: [RSSImportItem], metadata: AppleEpisodeMetadata?) -> RSSImportItem? {
        guard let metadata else { return nil }
        if let guid = metadata.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty,
           let match = items.first(where: { $0.guid?.trimmingCharacters(in: .whitespacesAndNewlines) == guid }) {
            return match
        }
        let target = normalizedKey(metadata.title ?? "")
        guard !target.isEmpty else { return nil }
        if let exact = items.first(where: { normalizedKey($0.title ?? "") == target }) {
            return exact
        }
        return items.first { item in
            let candidate = normalizedKey(item.title ?? "")
            return !candidate.isEmpty && (candidate.contains(target) || target.contains(candidate))
        }
    }

    private func downloadData(
        from url: URL,
        maximumBytes: Int,
        acceptedTypes: [String]
    ) async throws -> (data: Data, finalURL: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(acceptedTypes.joined(separator: ", "), forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count <= maximumBytes,
              let finalURL = http.url else {
            throw PodcastImportError.invalidResponse
        }
        return (data, finalURL)
    }

    private func identifier(in text: String, pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: "id", with: "")
    }

    private func isLikelyAudioURL(_ url: URL) -> Bool {
        ["mp3", "m4a", "mp4", "aac", "wav", "ogg", "opus", "m3u8"]
            .contains(url.pathExtension.lowercased())
    }

    private func secureURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        return components.url
    }

    private func usefulPublisherSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = cleanHTML(value)
        let ignored = ["subscribe", "follow us", "support the show", "patreon", "sponsor", "advertisement", "credits"]
        let sentences = cleaned
            .split(whereSeparator: { ".!?".contains($0) })
            .map { normalizeWhitespace(String($0)) }
            .filter { sentence in
                sentence.split(whereSeparator: { $0.isWhitespace }).count >= 5
                    && !ignored.contains(where: { sentence.lowercased().contains($0) })
                    && !sentence.lowercased().contains("http")
            }

        var summary = ""
        for sentence in sentences {
            let candidate = summary.isEmpty ? "\(sentence)." : "\(summary) \(sentence)."
            if candidate.count > 900 { break }
            summary = candidate
            if summary.count >= 420 { break }
        }
        if !summary.isEmpty { return summary }
        let fallback = String(cleaned.prefix(900)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private func parseDuration(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        let seconds: Double
        if parts.count == 3 {
            seconds = (parts[0] * 3_600) + (parts[1] * 60) + parts[2]
        } else if parts.count == 2 {
            seconds = (parts[0] * 60) + parts[1]
        } else {
            seconds = parts[0]
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func decodeTranscriptJSON(_ data: Data) -> String? {
        if let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let text = rows.compactMap { $0["text"] as? String }.joined(separator: " ")
            if !text.isEmpty { return text }
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let segments = object["segments"] as? [[String: Any]] {
                let text = segments.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !text.isEmpty { return text }
            }
            return object["text"] as? String
        }
        return nil
    }

    private func cleanCaptions(_ captions: String) -> String {
        let lines = captions.components(separatedBy: .newlines)
        var spoken: [String] = []
        var skippingBlock = false
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                skippingBlock = false
                continue
            }
            if ["NOTE", "STYLE", "REGION"].contains(where: { line == $0 || line.hasPrefix("\($0) ") }) {
                skippingBlock = true
                continue
            }
            if skippingBlock || line == "WEBVTT" || line.contains("-->")
                || line.range(of: "^\\d+$", options: .regularExpression) != nil {
                continue
            }
            if lines.indices.contains(index + 1), lines[index + 1].contains("-->") { continue }
            let text = cleanHTML(line)
            if !text.isEmpty, spoken.last != text { spoken.append(text) }
        }
        return normalizeWhitespace(spoken.joined(separator: " "))
    }

    private func cleanHTML(_ value: String) -> String {
        let withoutScripts = value.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let withoutTags = withoutScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return normalizeWhitespace(
            withoutTags
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
        )
    }

    private func normalizedKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }
}

private struct AppleEpisodeMetadata {
    let guid: String?
    let title: String?
}

private struct AppleLookupResponse: Decodable {
    let results: [AppleLookupItem]
}

private struct AppleLookupItem: Decodable {
    let wrapperType: String?
    let feedUrl: String?
    let trackName: String?
    let episodeGuid: String?
    let collectionName: String?
    let previewUrl: String?
    let description: String?
    let shortDescription: String?
    let trackTimeMillis: Double?
}

private struct PodcastPageMetadata {
    let title: String?
    let summary: String?
    let feedURL: URL?
    let audioURL: URL?
    let isEpisode: Bool
}

private struct RSSImportItem {
    var title: String?
    var guid: String?
    var summary: String?
    var contentEncoded: String?
    var audioURL: URL?
    var transcriptURL: URL?
    var transcriptType: String?
    var duration: String?
}

private final class RSSImportParser: NSObject, XMLParserDelegate {
    private var items: [RSSImportItem] = []
    private var currentItem: RSSImportItem?
    private var currentText = ""

    func parse(data: Data) throws -> [RSSImportItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? PodcastImportError.unsupportedLink
        }
        return items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        if elementName == "item" { currentItem = RSSImportItem() }
        guard currentItem != nil else { return }
        if elementName == "enclosure", let value = attributeDict["url"], let url = secureURL(from: value) {
            currentItem?.audioURL = url
        }
        if elementName == "podcast:transcript" || elementName == "transcript" {
            if let value = attributeDict["url"], let url = secureURL(from: value) {
                currentItem?.transcriptURL = url
            }
            currentItem?.transcriptType = attributeDict["type"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": currentItem?.title = text
        case "guid": currentItem?.guid = text
        case "description", "itunes:summary":
            if currentItem?.summary?.isEmpty != false { currentItem?.summary = text }
        case "content:encoded": currentItem?.contentEncoded = text
        case "itunes:duration", "duration": currentItem?.duration = text
        case "item":
            if let currentItem { items.append(currentItem) }
            currentItem = nil
        default: break
        }
        currentText = ""
    }

    private func secureURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        return components.url
    }
}
