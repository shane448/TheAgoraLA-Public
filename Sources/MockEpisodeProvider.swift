import Foundation

enum MockEpisodeProvider {
    static let sample = Episode(
        id: UUID(),
        title: "Choose a podcast",
        audioURL: URL(fileURLWithPath: "/"),
        prompts: []
    )

}
