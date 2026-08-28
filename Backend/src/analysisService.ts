import { createHash } from "node:crypto";
import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";
import { analyzeTranscript } from "./promptPipeline.js";
import { transcribeRemoteAudio } from "./transcription.js";

export interface AnalysisJobInput {
  title?: string;
  audio_url?: string;
  transcript?: string;
  duration?: number;
  prompt_count: number;
  model?: string;
}

export async function processEpisodeAnalysis(options: {
  input: AnalysisJobInput;
  userID: string;
  openAI: AgoraOpenAI;
  config: AppConfig;
}) {
  let transcript = options.input.transcript?.replace(/\s+/g, " ").trim() ?? "";
  if (transcript.split(/\s+/).filter(Boolean).length < 120) {
    if (!options.input.audio_url) throw new Error("A complete transcript or public audio URL is required.");
    transcript = await transcribeRemoteAudio(options.input.audio_url, options.openAI, options.config);
  }
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  if (wordCount < 120 || wordCount > 100_000) {
    throw new Error("The transcript length is outside the supported range.");
  }
  const estimatedDuration = wordCount / 2.45;
  const duration = options.input.duration && options.input.duration > 10
    ? options.input.duration
    : estimatedDuration;
  const analysisConfig = options.input.model
    ? { ...options.config, models: { ...options.config.models, extraction: options.input.model, curation: options.input.model } }
    : options.config;
  const analysis = await analyzeTranscript({
    transcript,
    duration,
    desiredCount: Math.max(3, Math.min(12, options.input.prompt_count)),
    safetyID: createHash("sha256").update(options.userID).digest("hex"),
    openAI: options.openAI,
    config: analysisConfig,
  });
  return {
    title: options.input.title ?? "Podcast Episode",
    transcript,
    duration,
    summary: analysis.summary,
    prompts: analysis.prompts,
    full_transcript_processed: true,
  };
}
