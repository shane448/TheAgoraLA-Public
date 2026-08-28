import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechRecognitionManager: ObservableObject {
    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var inputName: String = "Microphone"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var hasDetectedVoice = false
    private(set) var lastVoiceActivityDate = Date.distantPast

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var hasInstalledInputTap = false
    private var recognitionSessionID = UUID()
    private var finalizationContinuation: CheckedContinuation<String, Never>?
    private var finalizationTimeoutTask: Task<Void, Never>?

    var authorizationNeedsSettings: Bool {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let microphoneStatus = AVAudioSession.sharedInstance().recordPermission
        return speechStatus == .denied
            || speechStatus == .restricted
            || microphoneStatus == .denied
    }

    func requestAuthorization() async -> Bool {
        let speechAuthorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechAuthorized = true
        case .notDetermined:
            speechAuthorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            speechAuthorized = false
        }

        guard speechAuthorized else { return false }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    @discardableResult
    func startRecording() async -> Bool {
        guard !isRecording else { return true }
        guard await requestAuthorization() else { return false }
        stopRecording()
        transcript = ""
        lastErrorMessage = nil
        inputLevel = 0
        hasDetectedVoice = false
        lastVoiceActivityDate = .distantPast

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
            if let builtInMicrophone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMicrophone)
            }
            #if targetEnvironment(simulator)
            inputName = "Mac microphone"
            #else
            inputName = session.currentRoute.inputs.first?.portName
                ?? session.preferredInput?.portName
                ?? "Microphone"
            #endif

            let node = audioEngine.inputNode
            let recordingFormat = node.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw SpeechRecognitionError.inputUnavailable
            }

            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            newRequest.taskHint = .dictation
            request = newRequest

            let sessionID = UUID()
            recognitionSessionID = sessionID
            recognitionTask = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if result?.isFinal == true || error != nil {
                        if let error, self.transcript.isEmpty {
                            self.lastErrorMessage = error.localizedDescription
                        }
                        self.recognitionDidFinish()
                    }
                }
            }
            guard recognitionTask != nil else {
                throw SpeechRecognitionError.recognizerUnavailable
            }

            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { [weak self] buffer, _ in
                newRequest.append(buffer)
                let level = Self.normalizedInputLevel(for: buffer)
                Task { @MainActor in
                    guard let self, self.recognitionSessionID == sessionID else { return }
                    self.inputLevel = level
                    if level >= 0.2 {
                        self.hasDetectedVoice = true
                        self.lastVoiceActivityDate = Date()
                    }
                }
            }
            hasInstalledInputTap = true
            try audioEngine.start()
            isRecording = true
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            stopRecording()
            return false
        }
    }

    func finishRecording() async -> String {
        guard isRecording else { return transcript }

        stopAudioCapture()
        return await withCheckedContinuation { continuation in
            finalizationContinuation = continuation
            request?.endAudio()
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.completeFinalization()
            }
        }
    }

    func stopRecording() {
        stopAudioCapture()
        recognitionSessionID = UUID()
        request?.endAudio()
        recognitionTask?.cancel()
        completeFinalization()
        clearRecognitionResources()
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        isRecording = false
        inputLevel = 0
    }

    private func recognitionDidFinish() {
        stopAudioCapture()
        completeFinalization()
        clearRecognitionResources()
    }

    private func completeFinalization() {
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        guard let continuation = finalizationContinuation else { return }
        finalizationContinuation = nil
        let finalTranscript = transcript
        clearRecognitionResources()
        continuation.resume(returning: finalTranscript)
    }

    private func clearRecognitionResources() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {}
    }

    private nonisolated static func normalizedInputLevel(for buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_000_1))
        return min(max(Double((decibels + 55) / 45), 0), 1)
    }
}

private enum SpeechRecognitionError: LocalizedError {
    case inputUnavailable
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            return "No microphone input is available."
        case .recognizerUnavailable:
            return "Speech recognition is temporarily unavailable."
        }
    }
}
