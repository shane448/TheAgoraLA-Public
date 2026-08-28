import SwiftUI

struct EpisodeTranscriptView: View {
    let title: String
    let transcript: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AgoraTag(text: "Full Transcript")
                        Text(title)
                            .font(AgoraTheme.cardValueFont)
                            .foregroundColor(AgoraTheme.ink)

                        AgoraCard {
                            Text(transcript)
                                .font(AgoraTheme.bodyFont)
                                .foregroundColor(AgoraTheme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
