import { createHash } from "node:crypto";
import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";
import { analyzeTranscript } from "./promptPipeline.js";
import {
  assertPublicHTTPSURL,
  downloadRemoteTranscript,
  transcribeRemoteAudio,
} from "./transcription.js";
import { spawn } from "node:child_process";

export interface AnalysisJobInput {
  title?: string;
  audio_url?: string;
  transcript?: string;
  transcript_url?: string;
  transcript_type?: string;
  duration?: number;
  prompt_count?: number;
  model?: string;
}

export function transcriptAppearsComplete(transcript: string, duration?: number): boolean {
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  if (wordCount < 120) return false;
  if (!duration || !Number.isFinite(duration) || duration < 600) return true;
  const estimatedSpokenDuration = wordCount / 2.6;
  return estimatedSpokenDuration >= duration * 0.35;
}

export async function processEpisodeAnalysis(options: {
  input: AnalysisJobInput;
  userID: string;
  openAI: AgoraOpenAI;
  config: AppConfig;
}) {
  const measuredDuration = options.input.audio_url
    ? await probeRemoteAudioDuration(options.input.audio_url)
    : undefined;
  let transcript = options.input.transcript?.replace(/\s+/g, " ").trim() ?? "";
  const knownDuration = measuredDuration ?? options.input.duration;
  if (!transcriptAppearsComplete(transcript, knownDuration) && options.input.transcript_url) {
    try {
      transcript = await downloadRemoteTranscript(
        options.input.transcript_url,
        options.input.transcript_type,
      );
    } catch (error) {
      if (!options.input.audio_url) throw error;
    }
  }
  if (!transcriptAppearsComplete(transcript, knownDuration)) {
    if (!options.input.audio_url) throw new Error("A complete transcript or public audio URL is required.");
    transcript = await transcribeRemoteAudio(options.input.audio_url, options.openAI, options.config);
  }
  const wordCount = transcript.split(/\s+/).filter(Boolean).length;
  if (wordCount < 120 || wordCount > 100_000) {
    throw new Error("The transcript length is outside the supported range.");
  }
  const estimatedDuration = wordCount / 2.45;
  const duration = knownDuration && knownDuration > 10
    ? knownDuration
    : estimatedDuration;
  const analysisConfig = options.input.model
    ? { ...options.config, models: { ...options.config.models, curation: options.input.model } }
    : options.config;
  const analysis = await analyzeTranscript({
    transcript,
    duration,
    ...(options.input.prompt_count == null
      ? {}
      : { desiredCount: Math.max(3, Math.min(12, options.input.prompt_count)) }),
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

async function probeRemoteAudioDuration(audioURL: string): Promise<number | undefined> {
  try {
    const url = new URL(audioURL);
    await assertPublicHTTPSURL(url);
    const output = await runProcessCapture(
      "ffprobe",
      [
        "-v", "error",
        "-rw_timeout", "10000000",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        url.toString(),
      ],
      15_000,
    );
    const duration = Number(output.trim());
    return Number.isFinite(duration) && duration >= 1 && duration <= 86_400
      ? duration
      : undefined;
  } catch {
    return undefined;
  }
}

function runProcessCapture(command: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    let errorOutput = "";
    let settled = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error(`${command} timed out.`)));
    }, timeoutMs);
    const finish = (action: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      action();
    };
    child.stdout.on("data", (chunk) => { output += String(chunk).slice(0, 2_000); });
    child.stderr.on("data", (chunk) => { errorOutput += String(chunk).slice(0, 2_000); });
    child.on("error", (error) => finish(() => reject(error)));
    child.on("close", (code) => {
      if (code === 0) finish(() => resolve(output));
      else finish(() => reject(new Error(errorOutput || `${command} exited with ${code}.`)));
    });
  });
}
