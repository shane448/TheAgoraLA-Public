import SwiftUI

struct InteractivePromptView: View {
    let prompt: Prompt
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var pointsStore: PointsStore

    var body: some View {
        AgoraCard {
            VStack(spacing: 16) {
                HStack {
                    Text("Agora Check-In")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    Spacer()

                    AgoraTag(text: "Live")
                }

                Text(prompt.question)
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Response")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    TextEditor(text: $viewModel.answerText)
                        .frame(height: 120)
                        .padding(10)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                        .disabled(
                            viewModel.drivingModeEnabled
                                && (viewModel.drivingPromptState == .listening
                                    || viewModel.drivingPromptState == .submitting)
                        )
                }

                if viewModel.drivingModeEnabled {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: handsFreeStatusIcon)
                                .foregroundColor(AgoraTheme.accent)
                            Text("Complete Hands-Free")
                                .font(AgoraTheme.cardTitleFont)
                                .foregroundColor(AgoraTheme.ink)
                        }

                        if !viewModel.drivingStatusText.isEmpty {
                            Text(viewModel.drivingStatusText)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        if viewModel.drivingPromptState == .listening {
                            VStack(spacing: 6) {
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(AgoraTheme.inkMuted.opacity(0.14))
                                        Capsule()
                                            .fill(AgoraTheme.accentGradient)
                                            .frame(
                                                width: max(
                                                    8,
                                                    geometry.size.width * viewModel.speechManager.inputLevel
                                                )
                                            )
                                    }
                                }
                                .frame(height: 8)
                                .animation(
                                    .linear(duration: 0.08),
                                    value: viewModel.speechManager.inputLevel
                                )
                                .accessibilityLabel("Microphone input level")
                                .accessibilityValue(
                                    viewModel.speechManager.hasDetectedVoice
                                        ? "Voice detected"
                                        : "Waiting for speech"
                                )

                                Text(
                                    viewModel.speechManager.hasDetectedVoice
                                        ? "Voice detected. Submit is automatic when you finish."
                                        : "Start speaking when you are ready."
                                )
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            }
                            .transition(.opacity)
                        }

                        if viewModel.drivingPromptState == .speakingFeedback {
                            Button {
                                viewModel.stopFeedbackNarration()
                            } label: {
                                Label("Stop Feedback", systemImage: "stop.fill")
                                    .font(AgoraTheme.bodyFont.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                            .accessibilityHint("Stops the narrator and keeps the written feedback on screen")
                        } else {
                            Button {
                                viewModel.drivingMicTapped()
                            } label: {
                                Image(systemName: viewModel.speechManager.isRecording ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(AgoraTheme.inkOnAccent)
                                    .frame(width: 110, height: 110)
                                    .background(Circle().fill(AgoraTheme.accentGradient))
                                    .shadow(color: AgoraTheme.shadow, radius: 10, x: 0, y: 6)
                            }
                            .accessibilityLabel(viewModel.speechManager.isRecording ? "Stop recording" : "Start recording")
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Button(viewModel.speechManager.isRecording ? "Stop" : "Speak") {
                            viewModel.toggleRecording()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())

                        Button("Use Transcript") {
                            viewModel.answerText = viewModel.speechManager.transcript
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                }

                if viewModel.isEvaluating {
                    ProgressView("Evaluating...")
                        .font(AgoraTheme.bodyFont)
                }

                if !viewModel.feedbackText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Score")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)

                            Spacer()

                            Text("\(viewModel.lastScore)/100")
                                .font(AgoraTheme.cardTitleFont)
                                .foregroundColor(AgoraTheme.ink)
                        }

                        HStack {
                            Text("Grade \(viewModel.lastGrade.rawValue)")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Text("\(viewModel.lastAwardedPoints) Agora Points earned")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        AgoraExpandableText(
                            text: viewModel.feedbackText,
                            collapsedLineLimit: 7,
                            expansionThreshold: 320
                        )

                        Divider()

                        Text("Podcast-supported answer")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        AgoraExpandableText(
                            text: prompt.expectedAnswer,
                            collapsedLineLimit: 5,
                            expansionThreshold: 240,
                            color: AgoraTheme.ink
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button("Submit") {
                        Task {
                            await viewModel.submitAnswer(pointsStore: pointsStore)
                        }
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .disabled(
                        viewModel.drivingModeEnabled
                            || viewModel.isEvaluating
                            || !viewModel.canSubmitActiveAnswer
                    )

                    Button("Continue") {
                        viewModel.continuePlayback()
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .onReceive(viewModel.speechManager.$transcript) { transcript in
            guard viewModel.speechManager.isRecording else { return }
            viewModel.answerText = transcript
        }
        .onChange(of: viewModel.answerText) { _ in
            viewModel.activeAnswerDidChange()
        }
    }

    private var handsFreeStatusIcon: String {
        switch viewModel.drivingPromptState {
        case .listening:
            return "waveform"
        case .submitting:
            return "sparkles"
        case .announcingPrompt, .speakingFeedback, .retryingListening:
            return "speaker.wave.2.fill"
        case .idle:
            return "waveform.and.mic"
        }
    }
}
