import Foundation

struct AIResult {
    let score: Int
    let grade: PromptGrade
    let feedback: String
    let awardedPoints: Int
    let usedOfflineEstimate: Bool

    init(
        score: Int,
        grade: PromptGrade,
        feedback: String,
        awardedPoints: Int,
        usedOfflineEstimate: Bool = false
    ) {
        self.score = score
        self.grade = grade
        self.feedback = feedback
        self.awardedPoints = awardedPoints
        self.usedOfflineEstimate = usedOfflineEstimate
    }
}

enum AIServiceError: LocalizedError {
    case transcriptTooShort
    case invalidResponse
    case noQualityPrompts

    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "The transcript is too short to create reliable questions."
        case .invalidResponse:
            return "The AI service returned an invalid response."
        case .noQualityPrompts:
            return "The AI could not produce questions that passed the transcript-grounding checks."
        }
    }
}

struct TranscriptionResult {
    let transcript: String
    let duration: Double?
}

struct EpisodeAnalysisResult {
    let transcript: String
    let duration: Double
    let summary: String
    let prompts: [Prompt]
    let recommendedPromptCount: Int
    let contentDepthLabel: String
}

struct EpisodeLearningPlan: Decodable {
    struct Priority: Decodable {
        let id: String
        let title: String
        let importanceReason: String
        let evidenceQuote: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case id, title
            case importanceReason = "importance_reason"
            case evidenceQuote = "evidence_quote"
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    let contentDepthScore: Double
    let recommendedPromptCount: Int
    let priorities: [Priority]

    enum CodingKeys: String, CodingKey {
        case contentDepthScore = "content_depth_score"
        case recommendedPromptCount = "recommended_prompt_count"
        case priorities
    }

    var depthLabel: String {
        switch contentDepthScore {
        case 0.8...: return "Deep"
        case 0.58..<0.8: return "Substantial"
        case 0.38..<0.58: return "Focused"
        default: return "Light"
        }
    }
}

private struct GeneratedPrompt: Decodable {
    struct Scores: Decodable {
        let overall: Double?
        let importance: Double?
        let specificity: Double?
        let answerAlignment: Double?
        let grounding: Double?

        enum CodingKeys: String, CodingKey {
            case overall
            case importance = "importance_to_listener"
            case specificity = "episode_specificity"
            case answerAlignment = "answer_alignment"
            case grounding
        }
    }

    struct Evidence: Decodable {
        let quote: String
        let startSeconds: Double?
        let endSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case quote
            case startSeconds
            case endSeconds
            case startSecondsSnake = "start_seconds"
            case endSecondsSnake = "end_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quote = try container.decodeIfPresent(String.self, forKey: .quote) ?? ""
            startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds)
                ?? container.decodeIfPresent(Double.self, forKey: .startSecondsSnake)
            endSeconds = try container.decodeIfPresent(Double.self, forKey: .endSeconds)
                ?? container.decodeIfPresent(Double.self, forKey: .endSecondsSnake)
        }
    }

    let time: Double?
    let priorityID: String?
    let question: String
    let expectedAnswer: String
    let scores: Scores?
    let evidence: [Evidence]
    let passesQualityGates: Bool?

    enum CodingKeys: String, CodingKey {
        case time
        case priorityID
        case priorityIDSnake = "priority_id"
        case question
        case expectedAnswer
        case expectedAnswerSnake = "expected_answer"
        case scores
        case evidence
        case passesQualityGates
        case passesQualityGatesSnake = "passes_quality_gates"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(Double.self, forKey: .time)
        priorityID = try container.decodeIfPresent(String.self, forKey: .priorityID)
            ?? container.decodeIfPresent(String.self, forKey: .priorityIDSnake)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        expectedAnswer = try container.decodeIfPresent(String.self, forKey: .expectedAnswer)
            ?? container.decodeIfPresent(String.self, forKey: .expectedAnswerSnake)
            ?? ""
        scores = try container.decodeIfPresent(Scores.self, forKey: .scores)
        evidence = try container.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
        passesQualityGates = try container.decodeIfPresent(Bool.self, forKey: .passesQualityGates)
            ?? container.decodeIfPresent(Bool.self, forKey: .passesQualityGatesSnake)
    }
}

private struct GeneratedPromptEnvelope: Decodable {
    let prompts: [GeneratedPrompt]
}

private struct FastEpisodeAnalysisEnvelope: Decodable {
    let summary: String
    let contentDepthScore: Double
    let recommendedPromptCount: Int
    let priorities: [EpisodeLearningPlan.Priority]
    let prompts: [GeneratedPrompt]

    enum CodingKeys: String, CodingKey {
        case summary, priorities, prompts
        case contentDepthScore = "content_depth_score"
        case recommendedPromptCount = "recommended_prompt_count"
    }
}

final class AIService {
    private let personalAI = OpenRouterClient()

    func evaluateAnswer(
        question: String,
        expectedAnswer: String,
        userAnswer: String,
        transcript: String? = nil,
        progressSeconds: Double? = nil
    ) async -> AIResult {
        do {
            let score = try await personalAI.score(
                question: question,
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer
            )
            let boundedScore = min(max(score.score, 0), 100)
            let grade = PromptGrade.from(score: boundedScore)
            let remote = AIResult(
                score: boundedScore,
                grade: grade,
                feedback: score.feedback,
                awardedPoints: grade.pointsAwarded
            )
            return remote
        } catch {
#if DEBUG
            print("[AIService] Online grading failed: \(String(describing: error))")
#endif
            let local = localScore(
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer,
                progressSeconds: progressSeconds
            )
            return AIResult(
                score: local.score,
                grade: local.grade,
                feedback: "\(offlineGradingExplanation(for: error)) \(local.feedback)",
                awardedPoints: local.awardedPoints,
                usedOfflineEstimate: true
            )
        }
    }

    private func offlineGradingExplanation(for error: Error) -> String {
        if let providerError = error as? OpenRouterClientError {
            switch providerError {
            case .notConnected:
                return "No AI key was available for this grading request, so this is an offline estimate."
            case .insufficientCredits:
                return "Your AI account is connected, but the provider reported that it needs credits. This is an offline estimate."
            case .authenticationExpired:
                return "Your saved AI sign-in has expired. This is an offline estimate until you reconnect."
            case .service, .invalidResponse, .audioUnavailable, .audioTooLarge:
                return "Your AI account is connected, but online grading was temporarily unavailable. This is an offline estimate."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Your AI account is connected, but online grading took too long. This is an offline estimate."
            case .notConnectedToInternet, .networkConnectionLost:
                return "Your AI account is connected, but the network was unavailable. This is an offline estimate."
            default:
                break
            }
        }
        return "Your AI account is connected, but online grading could not finish. This is an offline estimate."
    }

    func generatePrompts(
        transcript: String,
        audioDuration: Double,
        desiredCount: Int = 3
    ) async throws -> [Prompt] {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(trimmedTranscript) >= 120 else { throw AIServiceError.transcriptTooShort }

        let duration = resolvedDuration(audioDuration: audioDuration, transcript: trimmedTranscript)
        let requestedCount = max(3, min(12, desiredCount))
        let learningPlan = try await personalAI.analyzeLearningPlan(
            transcript: trimmedTranscript,
            duration: duration
        )
        let candidates = try await fetchPromptCandidates(
            transcript: trimmedTranscript,
            duration: duration,
            count: min(20, max(8, requestedCount * 2)),
            learningPlan: learningPlan
        )
        let selected = selectBestCandidates(candidates, desiredCount: requestedCount)
        guard !selected.isEmpty else { throw AIServiceError.noQualityPrompts }
        return selected.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    func transcribeAudio(
        at audioURL: URL,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        try await personalAI.transcribe(audioURL: audioURL, progress: progress)
    }

    func summarizeEpisode(transcript: String) async throws -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(trimmedTranscript) >= 120 else { throw AIServiceError.transcriptTooShort }
        let summary = try await personalAI.summarize(transcript: trimmedTranscript)
        guard wordCount(summary) >= 30 else { throw AIServiceError.invalidResponse }
        return summary
    }

    func analyzeEpisode(
        title: String,
        audioURL: URL?,
        transcript: String?,
        audioDuration: Double?,
        desiredCount: Int? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EpisodeAnalysisResult {
        let completeTranscript = transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTranscript = completeTranscript.map { wordCount($0) >= 120 ? $0 : nil } ?? nil
        let resolvedTranscript: String
        let transcriptionDuration: Double?
        if let usableTranscript {
            resolvedTranscript = usableTranscript
            transcriptionDuration = nil
        } else if let audioURL {
            let transcription = try await personalAI.transcribe(audioURL: audioURL, progress: progress)
            resolvedTranscript = transcription.transcript
            transcriptionDuration = transcription.duration
        } else {
            throw AIServiceError.transcriptTooShort
        }

        let duration = resolvedDuration(
            audioDuration: audioDuration ?? transcriptionDuration ?? 0,
            transcript: resolvedTranscript
        )
        progress("Scanning every section of the transcript in parallel...")
        let editorial: FastEpisodeAnalysisEnvelope
        do {
            let fastData = try await personalAI.analyzeEpisodeFast(
                transcript: resolvedTranscript,
                duration: duration,
                desiredCount: desiredCount
            )
            guard let decoded = try? JSONDecoder().decode(FastEpisodeAnalysisEnvelope.self, from: fastData),
                  !decoded.priorities.isEmpty,
                  !decoded.prompts.isEmpty else {
                throw AIServiceError.invalidResponse
            }
            editorial = decoded
        } catch {
            try Task.checkCancellation()
            if let providerError = error as? OpenRouterClientError {
                switch providerError {
                case .notConnected, .insufficientCredits, .authenticationExpired:
                    throw providerError
                case .service, .invalidResponse, .audioUnavailable, .audioTooLarge:
                    break
                }
            }
            progress("Using the full-depth editorial fallback...")
            return try await analyzeEpisodeLegacy(
                transcript: resolvedTranscript,
                duration: duration,
                desiredCount: desiredCount
            )
        }
        let learningPlan = EpisodeLearningPlan(
            contentDepthScore: editorial.contentDepthScore,
            recommendedPromptCount: editorial.recommendedPromptCount,
            priorities: editorial.priorities
        )
        let recommendedCount = automaticPromptCount(duration: duration, learningPlan: learningPlan)
        let requestedCount = desiredCount.map { max(3, min(12, $0)) } ?? recommendedCount
        progress("Verifying evidence and selecting the strongest questions...")
        let validated = editorial.prompts.compactMap {
            validate($0, transcript: resolvedTranscript, duration: duration)
        }
        let promptValues = selectBestCandidates(validated, desiredCount: requestedCount)
        guard !promptValues.isEmpty else { throw AIServiceError.noQualityPrompts }
        let summaryValue = editorial.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(summaryValue) >= 30 else { throw AIServiceError.invalidResponse }
        return EpisodeAnalysisResult(
            transcript: resolvedTranscript,
            duration: duration,
            summary: summaryValue,
            prompts: promptValues.sorted { $0.timestampSeconds < $1.timestampSeconds },
            recommendedPromptCount: recommendedCount,
            contentDepthLabel: learningPlan.depthLabel
        )
    }

    private func analyzeEpisodeLegacy(
        transcript: String,
        duration: Double,
        desiredCount: Int?
    ) async throws -> EpisodeAnalysisResult {
        async let summaryTask = personalAI.summarize(transcript: transcript)
        let learningPlan = try await personalAI.analyzeLearningPlan(transcript: transcript, duration: duration)
        let recommendedCount = automaticPromptCount(duration: duration, learningPlan: learningPlan)
        let requestedCount = desiredCount.map { max(3, min(12, $0)) } ?? recommendedCount
        async let promptsTask = generatePersonalPrompts(
            transcript: transcript,
            duration: duration,
            requestedCount: requestedCount,
            learningPlan: learningPlan
        )
        let (summary, prompts) = try await (summaryTask, promptsTask)
        return EpisodeAnalysisResult(
            transcript: transcript,
            duration: duration,
            summary: summary,
            prompts: prompts,
            recommendedPromptCount: recommendedCount,
            contentDepthLabel: learningPlan.depthLabel
        )
    }

    private struct ValidatedCandidate {
        let prompt: Prompt
        let score: Double
        let priorityID: String?
    }

    private func fetchPromptCandidates(
        transcript: String,
        duration: Double,
        count: Int,
        learningPlan: EpisodeLearningPlan
    ) async throws -> [ValidatedCandidate] {
        let data = try await personalAI.generatePromptData(
            transcript: transcript,
            duration: duration,
            candidateCount: count,
            learningPlan: learningPlan
        )
        let generated = decodeGeneratedPrompts(from: data)
        guard !generated.isEmpty else { throw AIServiceError.invalidResponse }
        return generated.compactMap {
            validate($0, transcript: transcript, duration: duration)
        }
    }

    private func generatePersonalPrompts(
        transcript: String,
        duration: Double,
        requestedCount: Int,
        learningPlan: EpisodeLearningPlan
    ) async throws -> [Prompt] {
        let candidates = try await fetchPromptCandidates(
            transcript: transcript,
            duration: duration,
            count: min(20, max(8, requestedCount * 2)),
            learningPlan: learningPlan
        )
        let selected = selectBestCandidates(candidates, desiredCount: requestedCount)
        guard !selected.isEmpty else { throw AIServiceError.noQualityPrompts }
        return selected.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    private func validate(
        _ generated: GeneratedPrompt,
        transcript: String,
        duration: Double
    ) -> ValidatedCandidate? {
        guard generated.passesQualityGates == true else { return nil }
        let scores = generated.scores
        guard scores?.overall.map({ $0 >= 0.78 }) ?? false else { return nil }
        guard scores?.importance.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.specificity.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.answerAlignment.map({ $0 >= 0.78 }) ?? true else { return nil }
        guard scores?.grounding.map({ $0 >= 0.78 }) ?? true else { return nil }

        let question = cleanedQuestion(generated.question)
        let answer = cleanedAnswer(generated.expectedAnswer)
        guard !isStockQuestion(question), wordCount(question) >= 7, wordCount(question) <= 36 else { return nil }
        guard wordCount(answer) >= 10, wordCount(answer) <= 110 else { return nil }

        let transcriptKey = normalizedText(transcript)
        let validEvidence = generated.evidence.filter { evidence in
            let key = normalizedText(evidence.quote)
            return key.count >= 20 && transcriptKey.contains(key)
        }
        let evidenceQuotes = validEvidence
            .map(\.quote)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !evidenceQuotes.isEmpty else { return nil }

        let evidenceTokens = meaningfulTokens(evidenceQuotes.joined(separator: " "))
        let questionTokens = meaningfulTokens(question)
        let answerTokens = meaningfulTokens(answer)
        guard !evidenceTokens.isEmpty, !questionTokens.isEmpty, !answerTokens.isEmpty else { return nil }

        let questionHits = questionTokens.intersection(evidenceTokens).count
        let answerCoverage = Double(answerTokens.intersection(evidenceTokens).count) / Double(answerTokens.count)
        let questionAnswerHits = questionTokens.intersection(answerTokens).count
        guard questionHits >= 2, answerCoverage >= 0.18, questionAnswerHits >= 1 else { return nil }

        let questionCoverage = Double(questionHits) / Double(max(min(questionTokens.count, 5), 1))
        guard questionCoverage >= 0.4 else { return nil }

        guard let timestamp = promptTimestamp(
            generatedTime: generated.time,
            evidence: validEvidence,
            normalizedTranscript: transcriptKey,
            duration: duration
        ) else { return nil }
        let combinedScore = ((scores?.overall ?? 0) * 0.30)
            + ((scores?.importance ?? 0) * 0.25)
            + ((scores?.specificity ?? 0) * 0.15)
            + ((scores?.answerAlignment ?? 0) * 0.15)
            + ((scores?.grounding ?? 0) * 0.10)
            + (questionCoverage * 0.03)
            + (answerCoverage * 0.02)
        return ValidatedCandidate(
            prompt: Prompt(
                id: UUID(),
                timestampSeconds: timestamp,
                question: question,
                expectedAnswer: answer,
                leadTimeSeconds: 0
            ),
            score: combinedScore,
            priorityID: generated.priorityID
        )
    }

    private func promptTimestamp(
        generatedTime: Double?,
        evidence: [GeneratedPrompt.Evidence],
        normalizedTranscript: String,
        duration: Double
    ) -> Double? {
        var answerEndCandidates: [Double] = []

        if let generatedTime, generatedTime.isFinite, generatedTime > 0 {
            answerEndCandidates.append(min(generatedTime, duration))
        }
        answerEndCandidates.append(contentsOf: evidence.compactMap { item in
            guard let end = item.endSeconds, end.isFinite, end > 0 else { return nil }
            return min(end, duration)
        })

        for item in evidence {
            let quote = normalizedText(item.quote)
            guard !quote.isEmpty,
                  let range = normalizedTranscript.range(of: quote, options: .backwards),
                  !normalizedTranscript.isEmpty else { continue }
            let charactersThroughAnswer = normalizedTranscript.distance(
                from: normalizedTranscript.startIndex,
                to: range.upperBound
            )
            let transcriptProgress = Double(charactersThroughAnswer) / Double(normalizedTranscript.count)
            answerEndCandidates.append(min(max(transcriptProgress, 0), 1) * duration)
        }

        guard let answerEnd = answerEndCandidates.max(), answerEnd.isFinite else { return nil }
        let listeningBuffer = min(12, max(6, duration * 0.0025))
        let earliestUsefulPrompt = min(20, max(6, duration * 0.03))
        return min(duration, max(answerEnd + listeningBuffer, earliestUsefulPrompt))
    }

    private func selectBestCandidates(
        _ candidates: [ValidatedCandidate],
        desiredCount: Int
    ) -> [Prompt] {
        let sorted = candidates.sorted { left, right in
            if abs(left.score - right.score) < 0.0001 {
                return left.prompt.timestampSeconds < right.prompt.timestampSeconds
            }
            return left.score > right.score
        }

        var selected: [ValidatedCandidate] = []
        for candidate in sorted {
            if selected.count >= desiredCount { break }
            let coversNewPriority = candidate.priorityID.map { id in
                !selected.contains(where: { $0.priorityID == id })
            } ?? true
            let isDistinct = selected.allSatisfy { existing in
                jaccardSimilarity(
                    meaningfulTokens(existing.prompt.question),
                    meaningfulTokens(candidate.prompt.question)
                ) < 0.68 && jaccardSimilarity(
                    meaningfulTokens(existing.prompt.expectedAnswer),
                    meaningfulTokens(candidate.prompt.expectedAnswer)
                ) < 0.76
            }
            if coversNewPriority && isDistinct { selected.append(candidate) }
        }

        if selected.count < desiredCount {
            for candidate in sorted where !selected.contains(where: { $0.prompt.id == candidate.prompt.id }) {
                if selected.count >= desiredCount { break }
                let isDistinct = selected.allSatisfy { existing in
                    jaccardSimilarity(
                        meaningfulTokens(existing.prompt.question),
                        meaningfulTokens(candidate.prompt.question)
                    ) < 0.68
                }
                if isDistinct { selected.append(candidate) }
            }
        }
        return selected.map(\.prompt)
    }

    private func automaticPromptCount(duration: Double, learningPlan: EpisodeLearningPlan) -> Int {
        let minutes = duration / 60
        let durationCount: Int
        switch minutes {
        case ..<15: durationCount = 3
        case ..<30: durationCount = 4
        case ..<45: durationCount = 5
        case ..<60: durationCount = 6
        case ..<90: durationCount = 8
        case ..<120: durationCount = 10
        default: durationCount = 12
        }

        let modelCount = max(3, min(12, learningPlan.recommendedPromptCount))
        let depthAdjustment: Int
        switch learningPlan.contentDepthScore {
        case 0.82...: depthAdjustment = 2
        case 0.65..<0.82: depthAdjustment = 1
        case ..<0.38: depthAdjustment = -1
        default: depthAdjustment = 0
        }
        let blended = Int((Double(durationCount + modelCount) / 2).rounded()) + depthAdjustment
        let priorityCap = max(3, min(12, learningPlan.priorities.count))
        return max(3, min(priorityCap, blended))
    }

    private func decodeGeneratedPrompts(from data: Data) -> [GeneratedPrompt] {
        if let direct = try? JSONDecoder().decode([GeneratedPrompt].self, from: data) {
            return direct
        }
        if let envelope = try? JSONDecoder().decode(GeneratedPromptEnvelope.self, from: data) {
            return envelope.prompts
        }
        struct NestedEnvelope: Decodable {
            struct DataEnvelope: Decodable {
                let prompts: [GeneratedPrompt]
            }
            let data: DataEnvelope
        }
        return (try? JSONDecoder().decode(NestedEnvelope.self, from: data).data.prompts) ?? []
    }

    private func localScore(
        expectedAnswer: String,
        userAnswer: String,
        progressSeconds: Double?
    ) -> AIResult {
        let score = heuristicScore(expectedAnswer: expectedAnswer, userAnswer: userAnswer)
        let prefix: String
        if let progressSeconds, progressSeconds.isFinite {
            prefix = "You've listened up to \(formatTime(progressSeconds)). "
        } else {
            prefix = ""
        }

        let feedback: String
        switch score {
        case 85...100:
            feedback = prefix + "Strong answer. You captured the main idea; any missing detail is a refinement, not a major error."
        case 65..<85:
            feedback = prefix + "You're in the right ballpark and earned solid credit. To make the answer stronger, add this detail: \(expectedAnswer)"
        case 40..<65:
            feedback = prefix + "You identified part of the idea. Here is the key point to add: \(expectedAnswer)"
        default:
            feedback = prefix + "Not quite. The podcast's answer is: \(expectedAnswer)"
        }

        let grade = PromptGrade.from(score: score)
        return AIResult(score: score, grade: grade, feedback: feedback, awardedPoints: grade.pointsAwarded)
    }

    private func heuristicScore(expectedAnswer: String, userAnswer: String) -> Int {
        let expectedTokens = semanticTokens(expectedAnswer)
        let userTokens = semanticTokens(userAnswer)
        guard !expectedTokens.isEmpty, !userTokens.isEmpty else { return 0 }

        let overlap = expectedTokens.intersection(userTokens).count
        let precision = Double(overlap) / Double(userTokens.count)
        let recall = Double(overlap) / Double(expectedTokens.count)
        let f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0
        var score = max(f1, (precision * 0.7) + (recall * 0.3)) * 100

        let expectedConcepts = conceptTokens(expectedAnswer)
        let userConcepts = conceptTokens(userAnswer)
        if expectedConcepts.count >= 3, userConcepts.count >= 2 {
            let conceptOverlap = expectedConcepts.intersection(userConcepts).count
            let conceptRecall = Double(conceptOverlap) / Double(expectedConcepts.count)
            let conceptPrecision = Double(conceptOverlap) / Double(userConcepts.count)
            let conceptScore = ((conceptRecall * 0.8) + (conceptPrecision * 0.2)) * 100
            score = max(score, conceptScore)
        }

        if recall >= 0.75 {
            score += 10
        } else if recall >= 0.55 {
            score += 5
        }

        // A short answer can express the central idea without repeating every word
        // in a longer reference answer. Reward strong signal in the listener's words.
        if overlap >= 2, precision >= 0.7 {
            score = max(score, 85)
        } else if overlap >= 2, precision >= 0.45 {
            score = max(score, 72)
        } else if overlap >= 1, precision >= 0.5 {
            score = max(score, 60)
        }
        return min(100, max(0, Int(score.rounded())))
    }

    private func semanticTokens(_ text: String) -> Set<String> {
        Set(meaningfulTokens(text).map(canonicalToken))
    }

    private func conceptTokens(_ text: String) -> Set<String> {
        let normalized = normalizedText(text)
        var concepts = Set(meaningfulTokens(text).compactMap(conceptToken))
        let independencePhrases = [
            "from memory",
            "own words",
            "on your own",
            "without looking",
            "without the source",
            "without rereading",
            "without the transcript",
        ]
        if independencePhrases.contains(where: normalized.contains) {
            concepts.insert("independent")
        }
        return concepts
    }

    private func canonicalToken(_ token: String) -> String {
        conceptToken(token) ?? stemmedToken(token)
    }

    private func conceptToken(_ token: String) -> String? {
        let stem = stemmedToken(token)
        let concepts: [String: Set<String>] = [
            "retrieve": ["recall", "remember", "retriev"],
            "reveal": ["detect", "discover", "expos", "find", "highlight", "identif", "reveal", "show", "surfac", "uncover"],
            "gap": ["gap", "miss", "omission", "weakness"],
            "strengthen": ["build", "deepen", "improv", "reinforc", "solidif", "strengthen"],
            "memory": ["memor", "retention"],
            "reread": ["reread", "review", "revisit"],
            "familiarity": ["familiar", "recognit", "recogniz"],
            "independent": ["independent"],
        ]
        return concepts.first(where: { entry in
            entry.value.contains { alias in
                stem == alias || (min(stem.count, alias.count) >= 4 && (stem.hasPrefix(alias) || alias.hasPrefix(stem)))
            }
        })?.key
    }

    private func stemmedToken(_ token: String) -> String {
        var value = token
        let suffixes = ["ingly", "edly", "ation", "ition", "ment", "ness", "ingly", "ing", "ied", "ies", "ed", "es", "s"]
        for suffix in suffixes where value.count - suffix.count >= 4 && value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            if suffix == "ied" || suffix == "ies" { value.append("y") }
            break
        }
        return value
    }

    private func cleanedQuestion(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        value = value.prefix(1).uppercased() + value.dropFirst()
        if !value.hasSuffix("?") { value.append("?") }
        return value
    }

    private func cleanedAnswer(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isStockQuestion(_ question: String) -> Bool {
        let normalized = normalizedText(question)
        let bannedPhrases = [
            "what is the main idea",
            "summarize the episode",
            "what did they talk about",
            "what happened in this section",
            "what is this section about",
            "what is the strongest reason the speaker gives",
            "what assumption is doing the most work",
            "what should listeners take away",
            "what would a careful listener",
            "what hidden assumption",
            "what unresolved issue",
            "how does this segment",
            "how does this section",
            "according to the speaker",
            "what does the speaker say about",
            "which consequence of the argument",
            "what practical conclusion follows",
            "what thread introduced here",
            "do you agree",
            "what do you think",
            "in your opinion",
            "how would you apply",
        ]
        return normalized.isEmpty || bannedPhrases.contains { normalized.contains($0) }
    }

    private func meaningfulTokens(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are", "was",
            "were", "it", "this", "that", "as", "by", "at", "from", "be", "has", "have", "had", "do", "does",
            "did", "not", "we", "you", "they", "he", "she", "i", "me", "our", "your", "their", "about", "into",
            "out", "up", "down", "what", "why", "how", "when", "where", "which", "who", "according", "episode",
            "podcast", "speaker", "speakers", "says", "said", "claim", "claims", "idea", "point",
        ]
        return Set(
            normalizedText(text)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func jaccardSimilarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func resolvedDuration(audioDuration: Double, transcript: String) -> Double {
        if audioDuration.isFinite, audioDuration > 10 { return min(audioDuration, 86_400) }
        return max(180, min(86_400, Double(wordCount(transcript)) / 2.6))
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(Int(seconds), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
