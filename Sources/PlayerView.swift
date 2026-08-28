import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var pointsStore: PointsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 16) {
            AgoraCard {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Now Playing")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Text(viewModel.episode.title)
                            .font(AgoraTheme.cardValueFont)
                            .foregroundColor(AgoraTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubPosition : viewModel.currentTime },
                                set: { scrubPosition = $0 }
                            ),
                            in: 0...max(viewModel.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubPosition = viewModel.currentTime
                                    isScrubbing = true
                                } else {
                                    viewModel.seek(to: scrubPosition)
                                    isScrubbing = false
                                }
                            }
                        )
                            .tint(AgoraTheme.accent)
                            .accessibilityLabel("Episode position")
                            .accessibilityValue(formatTime(isScrubbing ? scrubPosition : viewModel.currentTime))

                        HStack {
                            Text(formatTime(isScrubbing ? scrubPosition : viewModel.currentTime))
                            Spacer()
                            Text(formatTime(viewModel.duration))
                        }
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    }

                    if let playbackError = viewModel.audioManager.playbackError {
                        Text(playbackError)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if viewModel.audioManager.isBuffering {
                        ProgressView("Buffering audio...")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 16) {
                        Button {
                            viewModel.skip(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }

                        Button {
                            viewModel.togglePlay()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    Circle().fill(AgoraTheme.accentGradient)
                                )
                                .foregroundColor(AgoraTheme.inkOnAccent)
                                .shadow(color: AgoraTheme.shadow, radius: 8, x: 0, y: 4)
                        }

                        Button {
                            viewModel.skip(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Interactive Mode")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text("AI prompts pause the audio for reflection.")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    Toggle(
                        "Interactive Prompts",
                        isOn: Binding(
                            get: { viewModel.interactiveModeEnabled },
                            set: { viewModel.setInteractiveMode($0) }
                        )
                    )
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.ink)
                        .toggleStyle(SwitchToggleStyle(tint: AgoraTheme.accent))

                    Divider()

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(AgoraTheme.accent)
                            .frame(width: 30)

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "Complete Hands-Free",
                                isOn: Binding(
                                    get: { viewModel.drivingModeEnabled },
                                    set: { viewModel.setHandsFreeMode($0) }
                                )
                            )
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.ink)
                            .toggleStyle(SwitchToggleStyle(tint: AgoraTheme.accent))

                            Text("Prompts are read aloud. Speak your answer, then hear your score and corrections automatically.")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Voice controls: \"Repeat the question,\" \"Start over,\" or \"Skip this question.\"")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            if let selectedVoice = selectedNarrationVoice {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Narrator")
                                        .font(AgoraTheme.tagFont.weight(.bold))
                                        .foregroundColor(AgoraTheme.ink)

                                    Menu {
                                        ForEach(viewModel.narrationVoiceOptions) { option in
                                            Button {
                                                viewModel.selectedNarrationVoiceID = option.id
                                            } label: {
                                                if option.id == viewModel.selectedNarrationVoiceID {
                                                    Label(option.name, systemImage: "checkmark")
                                                } else {
                                                    Text(option.name)
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(selectedVoice.name)
                                                .font(AgoraTheme.bodyFont.weight(.semibold))
                                                .foregroundColor(AgoraTheme.ink)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(AgoraTheme.accent)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.white.opacity(0.68))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                        )
                                        .cornerRadius(12)
                                    }
                                    .accessibilityLabel("Narrator voice")
                                    .accessibilityValue(selectedVoice.name)

                                    Text(selectedVoice.detail)
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)

                                    HStack(spacing: 16) {
                                        Button {
                                            viewModel.previewNarrationVoice()
                                        } label: {
                                            Label("Preview Voice", systemImage: "speaker.wave.2.fill")
                                        }
                                        .disabled(viewModel.drivingPromptState != .idle)
                                        .accessibilityHint("Plays a short sample using the selected narrator")

                                        if viewModel.selectedNarrationVoiceID != NarrationVoiceOption.automaticID {
                                            Button("Use Best Available") {
                                                viewModel.selectedNarrationVoiceID = NarrationVoiceOption.automaticID
                                            }
                                            .accessibilityHint("Automatically selects the highest-quality installed voice")
                                        }
                                    }
                                    .font(AgoraTheme.tagFont.weight(.semibold))
                                    .foregroundColor(AgoraTheme.accent)
                                }
                            }

                            #if targetEnvironment(simulator)
                            Text("Testing on Mac: in Simulator, choose I/O > Audio Input > Mac microphone.")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                            #endif

                            if !viewModel.drivingStatusText.isEmpty {
                                Text(viewModel.drivingStatusText)
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(
                                        viewModel.drivingModeEnabled ? AgoraTheme.accent : .red
                                    )
                            }

                            if viewModel.handsFreeNeedsSettings {
                                #if canImport(UIKit)
                                Button("Open Privacy Settings") {
                                    guard let settingsURL = URL(
                                        string: UIApplication.openSettingsURLString
                                    ) else { return }
                                    openURL(settingsURL)
                                }
                                .buttonStyle(AgoraOutlineButtonStyle())
                                .accessibilityHint("Opens microphone and speech permissions for The Agora LA")
                                #endif
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            if viewModel.showPrompt, let prompt = viewModel.activePrompt {
                InteractivePromptView(
                    prompt: prompt,
                    viewModel: viewModel,
                    pointsStore: pointsStore
                )
            }

            if !viewModel.queuedPrompts.isEmpty {
                promptQueue
            }
        }
        .onReceive(viewModel.audioManager.$currentTime) { time in
            viewModel.checkForPrompt(at: time)
        }
        .task {
            viewModel.bind(pointsStore: pointsStore)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                viewModel.appDidBecomeActive()
            case .inactive, .background:
                viewModel.appDidEnterBackground()
            @unknown default:
                break
            }
        }
    }

    private var promptQueue: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(viewModel.showPrompt ? "Earlier Check-Ins" : "Your Check-Ins")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Spacer()
                    AgoraTag(text: "\(viewModel.queuedPrompts.count)")
                }

                ForEach(Array(viewModel.queuedPrompts.enumerated()), id: \.element.id) { index, prompt in
                    Button {
                        viewModel.presentPrompt(prompt)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: viewModel.response(for: prompt)?.score == nil
                                  ? "questionmark.circle"
                                  : "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(AgoraTheme.accent)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(index == 0 && !viewModel.showPrompt ? "Most Recent" : "Previous Prompt")
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(AgoraTheme.inkMuted)
                                Text(prompt.question)
                                    .font(AgoraTheme.bodyFont)
                                    .foregroundColor(AgoraTheme.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                if let response = viewModel.response(for: prompt) {
                                    Text(response.score.map { "Score \($0)/100 - Tap to review or revise" }
                                         ?? "Draft saved - Tap to continue")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                } else {
                                    Text("Tap to answer")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                }
                            }

                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(AgoraTheme.inkMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < viewModel.queuedPrompts.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let intSeconds = Int(seconds)
        let minutes = intSeconds / 60
        let remainingSeconds = intSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private var selectedNarrationVoice: NarrationVoiceOption? {
        viewModel.narrationVoiceOptions.first {
            $0.id == viewModel.selectedNarrationVoiceID
        }
    }
}
