import Foundation

enum MockEpisodeProvider {
    static let sample = Episode(
        id: UUID(),
        title: "Choose a podcast",
        audioURL: URL(fileURLWithPath: "/"),
        prompts: []
    )

    static let reviewDemo = Episode(
        id: UUID(uuidString: "A60DD4CF-8B21-4A03-9D36-E43EC6C351AE")!,
        title: "Sample Lesson: Building Better Recall",
        audioURL: URL(fileURLWithPath: "/sample-lesson"),
        prompts: [
            Prompt(
                id: UUID(uuidString: "F8A1C13B-70A2-46ED-92E2-F4935924209A")!,
                timestampSeconds: 45,
                question: "Why does the sample lesson recommend recalling an idea before rereading it?",
                expectedAnswer: "The lesson says that attempting recall exposes what the listener can actually retrieve, identifies gaps, and strengthens the memory path. Rereading first can create familiarity without proving that the idea can be recalled independently.",
                leadTimeSeconds: 0
            )
        ],
        transcript: """
        This sample lesson was written by The Agora LA to demonstrate the app without using a publisher's podcast. It explains why active recall is more useful than immediate rereading when someone wants to remember an important idea.

        Rereading often feels productive because the words become familiar. Familiarity, however, is not the same as being able to explain the idea later. A listener can recognize a sentence while looking at it and still be unable to reconstruct its meaning after the page or transcript is closed.

        The lesson recommends pausing before rereading and trying to state the idea in your own words. That attempt reveals which parts can actually be retrieved and which details are missing. The effort also strengthens the path used to reach the memory. After the attempt, the listener can compare the response with the source, correct errors, and try again.

        The central point is not that rereading is useless. Rereading becomes more valuable after a retrieval attempt because it is then targeted at a known gap rather than used as a substitute for remembering.
        """,
        summary: "Active recall tests whether an idea can be retrieved rather than merely recognized. The lesson recommends attempting an explanation first, using the source to correct specific gaps, and then trying again."
    )
}
