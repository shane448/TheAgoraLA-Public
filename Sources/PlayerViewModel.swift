import Foundation
import Combine
import AVFoundation

private struct PromptHistorySnapshot: Codable {
    let responses: [PromptResponse]
    let encounteredPromptIDs: [UUID]
}

struct NarrationVoiceOption: Identifiable, Hashable {
    static let automaticID = "automatic"

    let id: String
    let name: String
    let detail: String
}

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    enum DrivingPromptState: Equatable {
        case idle
        case announcingPrompt
        case listening
        case submitting
        case speakingFeedback
        case retryingListening
    }

    @Published var episode: Episode = MockEpisodeProvider.sample
    @Published var activePrompt: Prompt?
    @Published var showPrompt = false
    @Published var answerText = ""
    @Published var feedbackText = ""
    @Published var lastScore: Int = 0
    @Published var lastGrade: PromptGrade = .f
    @Published var lastAwardedPoints: Int = 0
    @Published var isEvaluating = false
    @Published private(set) var hasScoredActivePrompt = false
    @Published var interactiveModeEnabled = true
    @Published var promptResults: [PromptResult] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var drivingModeEnabled = false
    @Published private(set) var drivingPromptState: DrivingPromptState = .idle
    @Published private(set) var drivingStatusText: String = ""
    @Published private(set) var handsFreeNeedsSettings = false
    @Published private(set) var narrationVoiceOptions: [NarrationVoiceOption]
    @Published var selectedNarrationVoiceID: String {
        didSet {
            UserDefaults.standard.set(selectedNarrationVoiceID, forKey: Self.narrationVoiceKey)
        }
    }
    @Published private(set) var promptResponses: [UUID: PromptResponse] = [:]
    @Published private(set) var encounteredPromptIDs: [UUID] = []

    let audioManager = AudioPlayerManager()
    let speechManager = SpeechRecognitionManager()
    let aiService = AIService()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var cancellables = Set<AnyCancellable>()

    private var promptedIDs = Set<UUID>()
    private var promptTriggerTimes: [UUID: Double] = [:]
    private let nowPlaying = NowPlayingManager.shared
    private weak var pointsStore: PointsStore?
    private var silenceWatchTask: Task<Void, Never>?
    private var speechWatchdogTask: Task<Void, Never>?
    private var transcriptUpdateDate = Date()
    private var listeningStartDate = Date()
    private var speechProgressDate = Date()
    private var emptyListeningRetryCount = 0
    private var activeSpeechUtterance: AVSpeechUtterance?
    private var activeSpeechState: DrivingPromptState?
    private var microphoneStartRetryCount = 0
    private var handsFreePausedForInterruption = false
    private var shouldResumeFeedbackAfterInterruption = false
    private static let narrationVoiceKey = "TheAgoraLA.NarrationVoice"

    override init() {
        let voiceOptions = Self.makeNarrationVoiceOptions()
        narrationVoiceOptions = voiceOptions
        let savedVoiceID = UserDefaults.standard.string(forKey: Self.narrationVoiceKey)
        selectedNarrationVoiceID = voiceOptions.contains(where: { $0.id == savedVoiceID })
            ? (savedVoiceID ?? NarrationVoiceOption.automaticID)
            : NarrationVoiceOption.automaticID
        super.init()
        speechSynthesizer.delegate = self
        loadPromptHistory(for: episode)
        if !episode.audioURL.isFileURL {
            audioManager.load(url: episode.audioURL)
        }
        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isPlaying = value
            }
            .store(in: &cancellables)

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                self?.currentTime = t
            }
            .store(in: &cancellables)

        audioManager.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] d in
                self?.duration = d
            }
            .store(in: &cancellables)

        // Wire remote command handlers
        nowPlaying.playHandler = { [weak self] in self?.audioManager.play() }
        nowPlaying.pauseHandler = { [weak self] in self?.audioManager.pause() }
        nowPlaying.skipForwardHandler = { [weak self] in self?.skip(by: 15) }
        nowPlaying.skipBackwardHandler = { [weak self] in self?.skip(by: -15) }
        nowPlaying.seekHandler = { [weak self] position in self?.seek(to: position) }

        audioManager.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self else { return }
                self.nowPlaying.update(elapsed: t, isPlaying: self.isPlaying, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        audioManager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self else { return }
                self.nowPlaying.update(elapsed: self.audioManager.currentTime, isPlaying: playing, duration: self.audioManager.duration)
            }
            .store(in: &cancellables)

        speechManager.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                guard self.drivingModeEnabled else { return }
                guard self.drivingPromptState == .listening else { return }
                self.answerText = text
                self.transcriptUpdateDate = Date()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &cancellables)
    }

    func bind(pointsStore: PointsStore) {
        self.pointsStore = pointsStore
    }

    func setInteractiveMode(_ enabled: Bool) {
        interactiveModeEnabled = enabled
        if !enabled, drivingModeEnabled {
            setHandsFreeMode(false)
        }
    }

    func setHandsFreeMode(_ enabled: Bool) {
        guard enabled != drivingModeEnabled else { return }
        drivingModeEnabled = enabled

        guard enabled else {
            handsFreeNeedsSettings = false
            cancelDrivingFlow()
            return
        }

        interactiveModeEnabled = true
        handsFreeNeedsSettings = false
        drivingStatusText = "Preparing microphone access..."
        Task {
            let authorized = await speechManager.requestAuthorization()
            guard drivingModeEnabled else { return }
            guard authorized else {
                drivingModeEnabled = false
                handsFreeNeedsSettings = speechManager.authorizationNeedsSettings
                drivingStatusText = "Allow Microphone and Speech Recognition in Settings to use hands-free mode."
                return
            }

            drivingStatusText = showPrompt ? "Starting hands-free prompt..." : "Ready for the next prompt."
            if let activePrompt, showPrompt {
                beginDrivingFlow(for: activePrompt)
            }
        }
    }

    func updateEpisode(_ updated: Episode) {
        let sourceChanged = episode.id != updated.id || episode.audioURL != updated.audioURL
        if sourceChanged { saveActiveDraft() }
        episode = updated
        promptTriggerTimes.removeAll()
        if sourceChanged {
            cancelDrivingFlow()
            if updated.audioURL.isFileURL {
                audioManager.pause()
            } else {
                audioManager.load(url: updated.audioURL)
            }
            nowPlaying.configure(title: updated.title, duration: 0)
            PlayerDurationCache.shared.duration = 0
            loadPromptHistory(for: updated)
            showPrompt = false
            activePrompt = nil
            hasScoredActivePrompt = false
        } else {
            let validPromptIDs = Set(updated.prompts.map(\.id))
            encounteredPromptIDs.removeAll { !validPromptIDs.contains($0) }
            promptedIDs.formIntersection(validPromptIDs)
            promptResponses = promptResponses.filter { validPromptIDs.contains($0.key) }
            persistPromptHistory()
            nowPlaying.configure(title: updated.title, duration: audioManager.duration)
            if let activePrompt, !updated.prompts.contains(where: { $0.id == activePrompt.id }) {
                cancelDrivingFlow()
                showPrompt = false
                self.activePrompt = nil
                hasScoredActivePrompt = false
            }
        }
    }

    func togglePlay() {
        if audioManager.isPlaying {
            audioManager.pause()
        } else {
            audioManager.play()
        }
    }

    func skip(by seconds: Double) {
        let duration = max(audioManager.duration, 0)
        let current = max(audioManager.currentTime, 0)
        let target = min(max(current + seconds, 0), duration)
        seek(to: target)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let playableDuration = max(audioManager.duration, 0)
        let target = playableDuration > 0
            ? min(max(seconds, 0), playableDuration)
            : max(seconds, 0)

        if interactiveModeEnabled, target > audioManager.currentTime + 1, playableDuration > 1 {
            let newlyPassed = episode.prompts
                .map { ($0, triggerTime(for: $0, duration: playableDuration)) }
                .filter { $0.1 <= target && !promptedIDs.contains($0.0.id) }
                .sorted { $0.1 < $1.1 }

            // A large seek should surface the most relevant reached prompt, not replay every missed one.
            for skipped in newlyPassed.dropLast() {
                markPromptEncountered(skipped.0)
            }
        }

        currentTime = target
        audioManager.seek(to: target)
    }

    func checkForPrompt(at time: Double) {
        guard interactiveModeEnabled else { return }
        guard !showPrompt else { return }
        guard audioManager.isPlaying else { return }
        let duration = audioManager.duration
        guard time.isFinite, time > 0.5, duration.isFinite, duration > 1 else { return }

        let scheduledPrompts = episode.prompts
            .map { prompt in
                (prompt, triggerTime(for: prompt, duration: duration))
            }
            .sorted { $0.1 < $1.1 }

        if let nextPrompt = scheduledPrompts
            .first(where: { $0.1 <= time && !promptedIDs.contains($0.0.id) })?.0 {
            activatePrompt(nextPrompt, beginDriving: drivingModeEnabled)
        }
    }

    private func triggerTime(for prompt: Prompt, duration: Double) -> Double {
        if let cached = promptTriggerTimes[prompt.id] { return cached }

        let alignedEnd = alignedAnswerEnd(for: prompt, duration: duration)
        let answerEnd: Double
        if prompt.timestampSeconds.isFinite, prompt.timestampSeconds > 1 {
            answerEnd = max(min(prompt.timestampSeconds, duration), alignedEnd ?? 0)
        } else {
            answerEnd = alignedEnd ?? duration
        }

        // leadTimeSeconds is retained for saved-data compatibility but now acts as a safe delay.
        let delay = prompt.leadTimeSeconds.isFinite ? max(prompt.leadTimeSeconds, 0) : 0
        let trigger = min(max(answerEnd + delay, 1), duration)
        promptTriggerTimes[prompt.id] = trigger
        return trigger
    }

    private func alignedAnswerEnd(for prompt: Prompt, duration: Double) -> Double? {
        guard let transcript = episode.transcript, !transcript.isEmpty else { return nil }
        let transcriptWords = normalizedTimingWords(transcript)
        let targetTokens = Set(normalizedTimingWords(prompt.question + " " + prompt.expectedAnswer))
        guard transcriptWords.count >= 20, targetTokens.count >= 3 else { return nil }

        let windowSize = min(110, max(50, transcriptWords.count / 80))
        let step = max(8, windowSize / 5)
        var bestStart = 0
        var bestHits = 0
        var start = 0

        while start < transcriptWords.count {
            let end = min(start + windowSize, transcriptWords.count)
            let hits = Set(transcriptWords[start..<end]).intersection(targetTokens).count
            // On ties, prefer the later passage so a repeated idea is never asked too early.
            if hits > 0, hits >= bestHits {
                bestHits = hits
                bestStart = start
            }
            if end == transcriptWords.count { break }
            start += step
        }

        let minimumHits = min(4, max(2, targetTokens.count / 8))
        guard bestHits >= minimumHits else { return nil }
        let answerWindowEnd = min(bestStart + windowSize, transcriptWords.count)
        let progress = Double(answerWindowEnd) / Double(transcriptWords.count)
        let listeningBuffer = min(12, max(6, duration * 0.0025))
        return min(duration, (progress * duration) + listeningBuffer)
    }

    private func normalizedTimingWords(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are",
            "was", "were", "it", "this", "that", "as", "by", "at", "from", "be", "has", "have", "had",
            "do", "does", "did", "not", "we", "you", "they", "he", "she", "what", "why", "how", "when",
            "where", "which", "who", "episode", "podcast", "speaker", "said", "says"
        ]
        return text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    func presentPrompt(_ prompt: Prompt) {
        saveActiveDraft()
        activatePrompt(prompt, beginDriving: drivingModeEnabled)
    }

    var queuedPrompts: [Prompt] {
        let promptsByID = Dictionary(uniqueKeysWithValues: episode.prompts.map { ($0.id, $0) })
        return encounteredPromptIDs.reversed().compactMap { id in
            guard activePrompt?.id != id || !showPrompt else { return nil }
            return promptsByID[id]
        }
    }

    func response(for prompt: Prompt) -> PromptResponse? {
        promptResponses[prompt.id]
    }

    var canSubmitActiveAnswer: Bool {
        guard let prompt = activePrompt else { return false }
        let answer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !isEvaluating else { return false }
        guard let saved = promptResponses[prompt.id], saved.score != nil else { return true }
        return saved.answer.trimmingCharacters(in: .whitespacesAndNewlines) != answer
    }

    func activeAnswerDidChange() {
        guard let prompt = activePrompt, let saved = promptResponses[prompt.id] else { return }
        guard saved.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            != answerText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        feedbackText = ""
        hasScoredActivePrompt = false
    }

    func submitAnswer(pointsStore: PointsStore) async {
        guard let prompt = activePrompt else { return }
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isEvaluating else { return }
        guard canSubmitActiveAnswer else { return }

        isEvaluating = true
        if drivingModeEnabled {
            drivingPromptState = .submitting
            drivingStatusText = "Grading your answer..."
        }
        defer { isEvaluating = false }

        let result = await aiService.evaluateAnswer(
            question: prompt.question,
            expectedAnswer: prompt.expectedAnswer,
            userAnswer: answerText,
            transcript: episode.transcript,
            progressSeconds: audioManager.currentTime
        )

        let previousAward = promptResponses[prompt.id]?.awardedPoints ?? 0
        let totalAward = max(previousAward, result.awardedPoints)
        let newlyEarnedPoints = max(totalAward - previousAward, 0)

        lastScore = result.score
        lastGrade = result.grade
        lastAwardedPoints = totalAward
        feedbackText = result.feedback
        hasScoredActivePrompt = true
        promptResponses[prompt.id] = PromptResponse(
            promptID: prompt.id,
            answer: answerText,
            score: result.score,
            grade: result.grade,
            awardedPoints: totalAward,
            feedback: result.feedback,
            lastUpdated: Date()
        )
        let promptResult = PromptResult(
            prompt: prompt,
            answer: answerText,
            score: result.score,
            grade: result.grade,
            awardedPoints: totalAward,
            feedback: result.feedback
        )
        if let index = promptResults.firstIndex(where: { $0.prompt.id == prompt.id }) {
            promptResults[index] = promptResult
        } else {
            promptResults.append(promptResult)
        }
        persistPromptHistory()

        if newlyEarnedPoints > 0 {
            pointsStore.add(points: newlyEarnedPoints)
        }
        if drivingModeEnabled {
            drivingPromptState = .speakingFeedback
            drivingStatusText = "Reading feedback..."
            speak(text: spokenFeedback(for: result))
        }
    }

    func continuePlayback() {
        saveActiveDraft()
        cancelDrivingFlow()
        showPrompt = false
        activePrompt = nil
        audioManager.play()
    }

    func toggleRecording() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            Task {
                if await speechManager.startRecording() == false {
                    drivingStatusText = "Microphone and speech access are required for voice answers."
                }
            }
        }
    }

    func drivingMicTapped() {
        if drivingPromptState == .listening || speechManager.isRecording {
            Task { await stopListeningAndSubmitIfPossible() }
        } else {
            Task { await startListening() }
        }
    }

    func stopFeedbackNarration() {
        guard drivingPromptState == .speakingFeedback else { return }
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        activeSpeechUtterance = nil
        activeSpeechState = nil
        shouldResumeFeedbackAfterInterruption = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        drivingPromptState = .idle
        drivingStatusText = "Feedback stopped. Review it below or continue the podcast."
    }

    func previewNarrationVoice() {
        guard drivingPromptState == .idle else { return }
        speak(text: "Welcome to The Agora. I’ll pause at important moments, listen to your answer, and help you reflect on what you heard.")
    }

    private func beginDrivingFlow(for prompt: Prompt) {
        cancelDrivingFlow()
        emptyListeningRetryCount = 0
        microphoneStartRetryCount = 0
        drivingPromptState = .announcingPrompt
        drivingStatusText = "Reading prompt..."
        speak(text: "Here’s your Agora check-in. \(prompt.question) Take your time, then answer in your own words.")
    }

    private func startListening() async {
        guard drivingModeEnabled else { return }
        guard showPrompt else { return }
        guard activePrompt != nil else { return }

        speechWatchdogTask?.cancel()
        drivingPromptState = .listening
        drivingStatusText = "Connecting to microphone..."
        answerText = ""
        transcriptUpdateDate = Date()
        listeningStartDate = Date()

        // Give the audio route a moment to move from text-to-speech to microphone input.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard drivingModeEnabled, showPrompt, drivingPromptState == .listening else { return }
        var started = await speechManager.startRecording()
        if !started, !speechManager.authorizationNeedsSettings, microphoneStartRetryCount == 0 {
            microphoneStartRetryCount += 1
            drivingStatusText = "Reconnecting to the microphone..."
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard drivingModeEnabled, showPrompt, drivingPromptState == .listening else { return }
            started = await speechManager.startRecording()
        }
        guard started else {
            if speechManager.authorizationNeedsSettings {
                drivingPromptState = .idle
                drivingModeEnabled = false
                handsFreeNeedsSettings = true
                drivingStatusText = "Microphone and Speech Recognition access must be enabled in Settings."
            } else {
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Microphone unavailable. Continuing playback..."
                speak(text: "I couldn't connect to the microphone. I'll continue the podcast, and you can revisit this question later.")
            }
            return
        }
        microphoneStartRetryCount = 0
        drivingStatusText = "Listening on \(speechManager.inputName)..."
        startSilenceWatch()
    }

    private func startSilenceWatch() {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { @MainActor in
            while !Task.isCancelled && drivingPromptState == .listening && showPrompt {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let transcript = speechManager.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let listenTime = Date().timeIntervalSince(listeningStartDate)

                if transcript.isEmpty {
                    if listenTime >= 15, !speechManager.hasDetectedVoice {
                        await handleEmptyListeningAttempt()
                        return
                    }
                    if listenTime >= 25, speechManager.hasDetectedVoice {
                        await handleEmptyListeningAttempt()
                        return
                    }
                    continue
                }

                if !speechManager.isRecording {
                    if transcript.isEmpty {
                        await handleEmptyListeningAttempt()
                    } else {
                        // Release the watcher handle without cancelling the task that performs grading.
                        silenceWatchTask = nil
                        await stopListeningAndSubmitIfPossible()
                    }
                    return
                }

                let latestActivity = max(transcriptUpdateDate, speechManager.lastVoiceActivityDate)
                let silence = Date().timeIntervalSince(latestActivity)
                if silence >= 2.8 && listenTime >= 2.5 {
                    // Cancelling this task here would also cancel its URLSession grading request.
                    silenceWatchTask = nil
                    await stopListeningAndSubmitIfPossible()
                    return
                }
            }
        }
    }

    private func stopListeningAndSubmitIfPossible() async {
        guard drivingPromptState == .listening else { return }
        drivingPromptState = .submitting
        drivingStatusText = "Finishing your response..."
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        let transcript = await speechManager.finishRecording()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard drivingModeEnabled, showPrompt else { return }
        guard !transcript.isEmpty else {
            await handleEmptyListeningAttempt()
            return
        }

        if let command = handsFreeCommand(from: transcript) {
            answerText = ""
            switch command {
            case .repeatQuestion:
                guard let prompt = activePrompt else { return }
                drivingPromptState = .announcingPrompt
                drivingStatusText = "Repeating the question..."
                speak(text: "Of course. \(prompt.question)")
            case .startOver:
                drivingPromptState = .retryingListening
                drivingStatusText = "Starting your answer over..."
                speak(text: "Okay. Start your answer again after I finish speaking.")
            case .skipQuestion:
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Skipping this question..."
                speak(text: "No problem. I'll save this question for later and continue the podcast.")
            }
            return
        }

        answerText = transcript
        guard let pointsStore else {
            drivingPromptState = .idle
            drivingStatusText = "Unable to grade right now."
            return
        }
        await submitAnswer(pointsStore: pointsStore)
    }

    private func handleEmptyListeningAttempt() async {
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        silenceWatchTask?.cancel()

        if emptyListeningRetryCount == 0, drivingModeEnabled, showPrompt {
            emptyListeningRetryCount += 1
            drivingPromptState = .retryingListening
            drivingStatusText = "No answer heard. Trying once more..."
            speak(text: "I didn't hear an answer. Please try again now.")
        } else {
            drivingPromptState = .speakingFeedback
            drivingStatusText = "No answer heard. Continuing playback..."
            speak(text: "I couldn't hear an answer, so I'll continue the podcast. You can revisit this prompt later.")
        }
    }

    private enum HandsFreeCommand {
        case repeatQuestion
        case startOver
        case skipQuestion
    }

    private func handsFreeCommand(from transcript: String) -> HandsFreeCommand? {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if [
            "repeat the question",
            "repeat that question",
            "say the question again",
            "ask the question again",
            "can you repeat",
            "could you repeat"
        ].contains(where: { normalized.contains($0) }) {
            return .repeatQuestion
        }

        if ["start over", "start my answer over", "erase my answer", "let me try again"]
            .contains(where: { normalized.contains($0) }) {
            return .startOver
        }

        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 7,
           ["skip this question", "skip the question", "continue the podcast", "move on"]
            .contains(where: { normalized.contains($0) }) {
            return .skipQuestion
        }
        return nil
    }

    func appDidEnterBackground() {
        guard drivingModeEnabled, showPrompt else { return }
        guard drivingPromptState == .announcingPrompt
                || drivingPromptState == .listening
                || drivingPromptState == .retryingListening else { return }

        handsFreePausedForInterruption = true
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        speechManager.stopRecording()
        activeSpeechUtterance = nil
        activeSpeechState = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
        drivingPromptState = .idle
        drivingStatusText = "Hands-free paused while the app is in the background."
    }

    func appDidBecomeActive() {
        guard handsFreePausedForInterruption else { return }
        handsFreePausedForInterruption = false
        guard drivingModeEnabled, showPrompt, let activePrompt else { return }
        beginDrivingFlow(for: activePrompt)
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard drivingModeEnabled, showPrompt else { return }
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            switch drivingPromptState {
            case .announcingPrompt, .listening, .retryingListening:
                appDidEnterBackground()
                drivingStatusText = "Hands-free paused for another audio session."
            case .speakingFeedback:
                shouldResumeFeedbackAfterInterruption = true
                activeSpeechUtterance = nil
                activeSpeechState = nil
                speechSynthesizer.stopSpeaking(at: .immediate)
                drivingPromptState = .idle
                drivingStatusText = "Feedback paused for another audio session."
            default:
                break
            }
        case .ended:
            if shouldResumeFeedbackAfterInterruption,
               activePrompt != nil,
               hasScoredActivePrompt {
                shouldResumeFeedbackAfterInterruption = false
                let result = AIResult(
                    score: lastScore,
                    grade: lastGrade,
                    feedback: feedbackText,
                    awardedPoints: lastAwardedPoints
                )
                drivingPromptState = .speakingFeedback
                drivingStatusText = "Reading feedback..."
                speak(text: spokenFeedback(for: result))
            } else {
                appDidBecomeActive()
            }
        @unknown default:
            break
        }
    }

    private func cancelDrivingFlow() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        drivingPromptState = .idle
        drivingStatusText = ""
        activeSpeechUtterance = nil
        activeSpeechState = nil
        handsFreePausedForInterruption = false
        shouldResumeFeedbackAfterInterruption = false
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func activatePrompt(_ prompt: Prompt, beginDriving: Bool) {
        audioManager.pause()
        markPromptEncountered(prompt)
        activePrompt = prompt
        showPrompt = true

        if let response = promptResponses[prompt.id] {
            answerText = response.answer
            feedbackText = response.feedback
            lastScore = response.score ?? 0
            lastGrade = response.grade ?? .f
            lastAwardedPoints = response.awardedPoints
            hasScoredActivePrompt = response.score != nil
        } else {
            answerText = ""
            feedbackText = ""
            lastScore = 0
            lastGrade = .f
            lastAwardedPoints = 0
            hasScoredActivePrompt = false
        }

        if beginDriving {
            beginDrivingFlow(for: prompt)
        } else {
            drivingPromptState = .idle
            drivingStatusText = ""
        }
    }

    private func markPromptEncountered(_ prompt: Prompt) {
        promptedIDs.insert(prompt.id)
        if !encounteredPromptIDs.contains(prompt.id) {
            encounteredPromptIDs.append(prompt.id)
        }
        persistPromptHistory()
    }

    private func saveActiveDraft() {
        guard let prompt = activePrompt else { return }
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty || promptResponses[prompt.id] != nil else { return }

        var response = promptResponses[prompt.id] ?? PromptResponse(
            promptID: prompt.id,
            answer: answerText,
            score: nil,
            grade: nil,
            awardedPoints: 0,
            feedback: "",
            lastUpdated: Date()
        )
        if response.answer.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedAnswer {
            response.score = nil
            response.grade = nil
            response.feedback = ""
        }
        response.answer = answerText
        response.lastUpdated = Date()
        promptResponses[prompt.id] = response
        persistPromptHistory()
    }

    private func loadPromptHistory(for episode: Episode) {
        guard let data = UserDefaults.standard.data(forKey: historyKey(for: episode.id)),
              let snapshot = try? JSONDecoder().decode(PromptHistorySnapshot.self, from: data) else {
            promptResponses = [:]
            encounteredPromptIDs = []
            promptedIDs = []
            return
        }
        let validPromptIDs = Set(episode.prompts.map(\.id))
        promptResponses = Dictionary(
            uniqueKeysWithValues: snapshot.responses
                .filter { validPromptIDs.contains($0.promptID) }
                .map { ($0.promptID, $0) }
        )
        encounteredPromptIDs = snapshot.encounteredPromptIDs.filter(validPromptIDs.contains)
        promptedIDs = Set(encounteredPromptIDs)
    }

    private func persistPromptHistory() {
        let snapshot = PromptHistorySnapshot(
            responses: Array(promptResponses.values),
            encounteredPromptIDs: encounteredPromptIDs
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: historyKey(for: episode.id))
    }

    private func historyKey(for episodeID: UUID) -> String {
        "TheAgoraLA.PromptHistory.\(episodeID.uuidString)"
    }

    private func speak(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activeSpeechUtterance = nil
        activeSpeechState = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {}
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedNarrationVoice()
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.98
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.12
        utterance.postUtteranceDelay = 0.22
        activeSpeechUtterance = utterance
        activeSpeechState = drivingPromptState
        speechProgressDate = Date()
        speechSynthesizer.speak(utterance)
        startSpeechWatchdog(for: drivingPromptState, utterance: utterance, text: text)
    }

    private func startSpeechWatchdog(
        for expectedState: DrivingPromptState,
        utterance: AVSpeechUtterance,
        text: String
    ) {
        speechWatchdogTask?.cancel()
        let wordCount = max(text.split(whereSeparator: { $0.isWhitespace }).count, 1)
        let timeout = min(max((Double(wordCount) / 2.2) + 5, 8), 90)

        speechWatchdogTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard drivingModeEnabled, showPrompt, drivingPromptState == expectedState else { return }
                guard activeSpeechUtterance === utterance else { return }

                let hasStalled = Date().timeIntervalSince(speechProgressDate) >= 5
                if !speechSynthesizer.isSpeaking || hasStalled || Date() >= deadline {
                    activeSpeechUtterance = nil
                    activeSpeechState = nil
                    speechSynthesizer.stopSpeaking(at: .immediate)
                    await advanceAfterSpeech(from: expectedState)
                    return
                }
            }
        }
    }

    private func advanceAfterSpeech(from completedState: DrivingPromptState) async {
        guard drivingModeEnabled, showPrompt, drivingPromptState == completedState else { return }
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil

        switch completedState {
        case .announcingPrompt, .retryingListening:
            await startListening()
        case .speakingFeedback:
            continuePlayback()
        default:
            break
        }
    }

    private func spokenFeedback(for result: AIResult) -> String {
        let scoreDescription = "You scored \(result.score) out of 100."
        return "\(scoreDescription) \(result.feedback)"
    }

    private func selectedNarrationVoice() -> AVSpeechSynthesisVoice? {
        let installedVoices = AVSpeechSynthesisVoice.speechVoices()
        if selectedNarrationVoiceID != NarrationVoiceOption.automaticID,
           let selected = installedVoices.first(where: { $0.identifier == selectedNarrationVoiceID }) {
            return selected
        }
        return Self.rankedEnglishVoices(installedVoices).first
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func makeNarrationVoiceOptions() -> [NarrationVoiceOption] {
        let automatic = NarrationVoiceOption(
            id: NarrationVoiceOption.automaticID,
            name: "Best Available",
            detail: "Automatically uses the clearest installed voice"
        )
        let installed = Array(rankedEnglishVoices(AVSpeechSynthesisVoice.speechVoices()).prefix(8))
        return [automatic] + installed.map { voice in
            NarrationVoiceOption(
                id: voice.identifier,
                name: voice.name,
                detail: "\(qualityName(voice.quality)) · \(voice.language)"
            )
        }
    }

    private static func rankedEnglishVoices(
        _ voices: [AVSpeechSynthesisVoice]
    ) -> [AVSpeechSynthesisVoice] {
        voices
            .filter {
                $0.language.lowercased().hasPrefix("en")
                    && isNarrationAppropriate($0)
            }
            .sorted { lhs, rhs in
                let leftScore = qualityRank(lhs.quality) * 100
                    + naturalVoiceRank(lhs.name)
                    + (lhs.language.lowercased() == "en-us" ? 5 : 0)
                let rightScore = qualityRank(rhs.quality) * 100
                    + naturalVoiceRank(rhs.name)
                    + (rhs.language.lowercased() == "en-us" ? 5 : 0)
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func isNarrationAppropriate(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, *), voice.voiceTraits.contains(.isNoveltyVoice) {
            return false
        }
        let noveltyNames: Set<String> = [
            "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos",
            "fred", "good news", "jester", "organ", "superstar", "trinoids",
            "whisper", "wobble", "zarvox"
        ]
        return !noveltyNames.contains(voice.name.lowercased())
    }

    private static func naturalVoiceRank(_ name: String) -> Int {
        let preferredNames = [
            "samantha", "ava", "allison", "susan", "alex", "tom", "aaron",
            "nicky", "jamie", "evan", "nathan", "daniel", "karen", "moira", "tessa"
        ]
        let normalizedName = name.lowercased()
        guard let index = preferredNames.firstIndex(where: { normalizedName.contains($0) }) else {
            return 0
        }
        return preferredNames.count - index + 10
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        case .default: return 1
        @unknown default: return 0
        }
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Standard"
        @unknown default: return "System"
        }
    }
}

extension PlayerViewModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.speechProgressDate = Date()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeSpeechUtterance === utterance,
                  let completedState = self.activeSpeechState else { return }
            self.activeSpeechUtterance = nil
            self.activeSpeechState = nil
            await self.advanceAfterSpeech(from: completedState)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.activeSpeechUtterance === utterance,
                  let completedState = self.activeSpeechState else { return }
            self.activeSpeechUtterance = nil
            self.activeSpeechState = nil
            await self.advanceAfterSpeech(from: completedState)
        }
    }
}
