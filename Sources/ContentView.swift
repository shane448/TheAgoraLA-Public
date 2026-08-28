import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @EnvironmentObject private var pointsStore: PointsStore
    @EnvironmentObject private var episodeStore: EpisodeStore
    @EnvironmentObject private var aiAccount: AIAccountStore
    @State private var showEditor = false
    @State private var showTranscript = false
    @State private var showAIAccount = false
    @State private var isSummaryExpanded = false

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header

                        if !hasUsableAI {
                            aiSetupCard
                        }

                        if hasConfiguredEpisode {
                            if !episodeStore.episode.audioURL.isFileURL {
                                PlayerView(viewModel: viewModel)
                            }

                            episodeOverviewCard
                            donationCard

                            if episodeStore.episode.audioURL.isFileURL,
                               let demoPrompt = episodeStore.episode.prompts.first {
                                demoPromptCard(demoPrompt)
                            }
                        } else {
                            emptyEpisodeCard
                            donationCard
                        }

                        Button("Edit Episode & Prompts") {
                            showEditor = true
                        }
                        .buttonStyle(AgoraPillButtonStyle())
                        .padding(.horizontal, 16)

                        pointsCard
                        legalLinks
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showEditor) {
                ScrollView {
                    PromptEditorView(episodeStore: episodeStore)
                        .padding(.vertical, 24)
                }
                .background(AgoraBackgroundView())
                .onDisappear {
                    viewModel.updateEpisode(episodeStore.episode)
                }
            }
            .sheet(isPresented: $showTranscript) {
                EpisodeTranscriptView(
                    title: episodeStore.episode.title,
                    transcript: episodeStore.episode.transcript ?? ""
                )
            }
            .sheet(isPresented: $showAIAccount) {
                AIAccountView()
                    .environmentObject(aiAccount)
            }
            .onAppear {
                viewModel.updateEpisode(episodeStore.episode)
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioDurationUpdated)) { notification in
                if let duration = notification.userInfo?["duration"] as? Double {
                    PlayerDurationCache.shared.duration = duration
                }
            }
            .onReceive(episodeStore.$episode) { updated in
                viewModel.updateEpisode(updated)
            }
            .onReceive(NotificationCenter.default.publisher(for: .aiConnectionInvalidated)) { _ in
                aiAccount.invalidateConnection()
            }
            .task {
                await aiAccount.refreshConnectionStatus()
            }
        }
    }

    private var hasConfiguredEpisode: Bool {
        !episodeStore.episode.audioURL.isFileURL
            || !(episodeStore.episode.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var hasUsableAI: Bool {
        aiAccount.isConnected
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("THE AGORA LA")
                .font(AgoraTheme.titleFont)
                .foregroundColor(AgoraTheme.ink)

            AgoraTag(text: "Interactive")
            Spacer()
            Button {
                showAIAccount = true
            } label: {
                Image(systemName: hasUsableAI ? "brain.head.profile.fill" : "person.badge.key.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AgoraTheme.cardSurface))
            }
            .accessibilityLabel(hasUsableAI ? "AI access ready" : "Set up AI access")
        }
        .padding(.horizontal, 20)
    }

    private var aiSetupCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                        .foregroundColor(AgoraTheme.accent)
                    Text("Connect Your AI")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                }
                Text("Connect a personal AI provider account. The Agora is free and never sells credits or receives payment for AI usage.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                Button("Connect Your AI") {
                    showAIAccount = true
                }
                .buttonStyle(AgoraPillButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var emptyEpisodeCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a podcast to begin")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Open the episode editor and paste an Apple Podcasts link or a direct audio link.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                Button("Explore a Sample Lesson") {
                    episodeStore.loadReviewDemo()
                }
                .buttonStyle(AgoraOutlineButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private func demoPromptCard(_ prompt: Prompt) -> some View {
        VStack(spacing: 12) {
            AgoraCard {
                VStack(alignment: .leading, spacing: 10) {
                    AgoraTag(text: "Offline Demo")
                    Text(prompt.question)
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.ink)
                    Button("Answer Sample Question") {
                        viewModel.presentPrompt(prompt)
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)

            if viewModel.showPrompt, viewModel.activePrompt?.id == prompt.id {
                InteractivePromptView(
                    prompt: prompt,
                    viewModel: viewModel,
                    pointsStore: pointsStore
                )
            }
        }
    }

    private var episodeOverviewCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Episode Brief")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Spacer()
                    AgoraTag(text: episodeStore.episode.transcript == nil ? "Preparing" : "Ready")
                }

                if let summary = episodeStore.episode.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    Text(summary)
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                        .lineLimit(isSummaryExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: isSummaryExpanded)

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isSummaryExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isSummaryExpanded ? "Show Less" : "Read More",
                            systemImage: isSummaryExpanded ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                    .accessibilityHint(isSummaryExpanded ? "Collapses the episode brief" : "Expands the episode brief")
                } else {
                    Text("Import the episode to prepare its summary and transcript.")
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }

                Button(episodeStore.episode.transcript == nil ? "Transcript is being prepared" : "View Full Transcript") {
                    showTranscript = true
                }
                .buttonStyle(AgoraOutlineButtonStyle())
                .disabled(episodeStore.episode.transcript == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .onChange(of: episodeStore.episode.id) { _ in
            isSummaryExpanded = false
        }
    }

    private var pointsCard: some View {
        NavigationLink(destination: PointsProgressView()) {
            AgoraCard {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agora Points")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)

                        Text("\(pointsStore.currentLevel.title) · \(pointsStore.totalPoints) points")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Text("View your training arc")
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.ink)
                    }

                    Spacer()

                    Image(systemName: pointsStore.currentLevel.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agora Points. \(pointsStore.currentLevel.title), \(pointsStore.totalPoints) points. View progress.")
        .padding(.horizontal, 16)
    }

    private var donationCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)
                    Text("Keep the Public Square Open")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Spacer()
                    AgoraTag(text: "501(c)(3)")
                }

                Text("Donations support free public forums, educational resources, distinguished speakers, wider media access, and The Agora's long-term public-learning mission.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: AppLinks.paypalDonation) {
                    HStack {
                        Text("Donate Securely with PayPal")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())

                Text("Opens The Agora LA's secure PayPal donation page. Donations never unlock app features.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var legalLinks: some View {
        HStack(spacing: 18) {
            Link("Privacy", destination: AppLinks.privacy)
            Link("Terms", destination: AppLinks.terms)
            Link("Support", destination: AppLinks.support)
        }
        .font(AgoraTheme.tagFont.weight(.semibold))
        .foregroundColor(AgoraTheme.inkMuted)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(PointsStore())
        .environmentObject(EpisodeStore())
        .environmentObject(AIAccountStore())
}
#endif
