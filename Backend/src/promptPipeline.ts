import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";

export interface TranscriptEvidence {
  quote: string;
  start_seconds: number;
  end_seconds: number;
}

export interface EpisodePrompt {
  time: number;
  question: string;
  expected_answer: string;
  evidence: TranscriptEvidence[];
  scores: {
    overall: number;
    importance_to_listener: number;
    episode_specificity: number;
    answer_alignment: number;
    grounding: number;
  };
  passes_quality_gates: boolean;
}

interface ExtractedIdea {
  title: string;
  claim: string;
  expected_answer: string;
  evidence_quote: string;
  approx_seconds: number;
  importance_reason: string;
  importance: number;
}

interface CuratedResponse {
  summary: string;
  prompts: EpisodePrompt[];
}

const extractionSchema = {
  type: "object",
  additionalProperties: false,
  required: ["ideas"],
  properties: {
    ideas: {
      type: "array",
      minItems: 2,
      maxItems: 12,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["title", "claim", "expected_answer", "evidence_quote", "approx_seconds", "importance_reason", "importance"],
        properties: {
          title: { type: "string" },
          claim: { type: "string" },
          expected_answer: { type: "string" },
          evidence_quote: { type: "string" },
          approx_seconds: { type: "number", minimum: 0 },
          importance_reason: { type: "string" },
          importance: { type: "number", minimum: 0, maximum: 1 },
        },
      },
    },
  },
} as const;

function curationSchema(candidateCount: number) {
  return {
    type: "object",
    additionalProperties: false,
    required: ["summary", "prompts"],
    properties: {
      summary: { type: "string" },
      prompts: {
        type: "array",
        minItems: candidateCount,
        maxItems: candidateCount,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["time", "question", "expected_answer", "evidence", "scores", "passes_quality_gates"],
          properties: {
            time: { type: "number", minimum: 0 },
            question: { type: "string" },
            expected_answer: { type: "string" },
            evidence: {
              type: "array",
              minItems: 1,
              maxItems: 2,
              items: {
                type: "object",
                additionalProperties: false,
                required: ["quote", "start_seconds", "end_seconds"],
                properties: {
                  quote: { type: "string" },
                  start_seconds: { type: "number", minimum: 0 },
                  end_seconds: { type: "number", minimum: 0 },
                },
              },
            },
            scores: {
              type: "object",
              additionalProperties: false,
              required: ["overall", "importance_to_listener", "episode_specificity", "answer_alignment", "grounding"],
              properties: {
                overall: { type: "number", minimum: 0, maximum: 1 },
                importance_to_listener: { type: "number", minimum: 0, maximum: 1 },
                episode_specificity: { type: "number", minimum: 0, maximum: 1 },
                answer_alignment: { type: "number", minimum: 0, maximum: 1 },
                grounding: { type: "number", minimum: 0, maximum: 1 },
              },
            },
            passes_quality_gates: { type: "boolean" },
          },
        },
      },
    },
  } as const;
}

export async function analyzeTranscript(options: {
  transcript: string;
  duration: number;
  desiredCount: number;
  safetyID: string;
  openAI: AgoraOpenAI;
  config: AppConfig;
}): Promise<{ summary: string; prompts: EpisodePrompt[] }> {
  const normalizedTranscript = normalizeWhitespace(options.transcript);
  const chunks = transcriptChunks(normalizedTranscript, options.duration);
  const extractedBatches = await mapConcurrent(chunks, 3, async (chunk, index) => {
    const response = await options.openAI.structured<{ ideas: ExtractedIdea[] }>({
      model: options.config.models.extraction,
      safetyID: options.safetyID,
      effort: "low",
      schemaName: "episode_idea_extraction",
      schema: extractionSchema,
      instructions: [
        "You are an evidence editor reading one section of a podcast transcript.",
        "Extract only consequential, episode-specific claims, explanations, distinctions, mechanisms, examples, disagreements, or conclusions.",
        "Every expected answer must directly state what the podcast says, and every evidence quote must be copied verbatim from the supplied section.",
        "Ignore advertisements, introductions, biographies, housekeeping, jokes without argumentative value, and facts answerable from general knowledge.",
      ].join(" "),
      input: `Section ${index + 1} of ${chunks.length}. Preserve the supplied approximate timestamps.\n\n${chunk}`,
    });
    return response.ideas;
  });

  const transcriptKey = normalizedText(normalizedTranscript);
  const ideas = extractedBatches.flat().filter((idea) => {
    const quoteKey = normalizedText(idea.evidence_quote);
    return quoteKey.length >= 30 && transcriptKey.includes(quoteKey) && idea.importance >= 0.55;
  });
  if (ideas.length < options.desiredCount) {
    throw new Error("The transcript did not yield enough evidence-backed ideas for a reliable analysis.");
  }

  const candidateCount = Math.min(
    ideas.length,
    18,
    Math.max(options.desiredCount * 2, 8, options.desiredCount),
  );
  const curated = await options.openAI.structured<CuratedResponse>({
    model: options.config.models.curation,
    safetyID: options.safetyID,
    effort: "high",
    schemaName: "episode_editorial_selection",
    schema: curationSchema(candidateCount),
    instructions: [
      "You are the senior learning editor for a podcast listening app.",
      "Judge the evidence-backed ideas from every part of the episode, then create difficult but fair listening checks about the most consequential content.",
      "Questions must name distinctive people, concepts, arguments, examples, events, or causal claims from this episode and must not use generic templates.",
      "Expected answers must answer their exact paired question using only the supplied podcast evidence.",
      "Return an accurate 100-170 word episode summary plus independently useful candidate prompts.",
      "Reject opinion questions, trivia, vague summaries, repeated ideas, ads, and anything answerable without listening.",
      "Set passes_quality_gates true only when every score is at least 0.78.",
    ].join(" "),
    input: `Episode duration: ${Math.round(options.duration)} seconds.\nRequested final prompts: ${options.desiredCount}.\n\nEVIDENCE-BACKED IDEAS FROM THE COMPLETE EPISODE:\n${JSON.stringify(ideas)}`,
  });

  const validated = validateAndRankPrompts(curated.prompts, normalizedTranscript, options.duration);
  const selected = selectDistinctPrompts(validated, options.desiredCount);
  if (selected.length < Math.min(3, options.desiredCount)) {
    throw new Error("The editorial candidates did not pass the grounding and answer-alignment checks.");
  }
  const summary = normalizeWhitespace(curated.summary);
  if (wordCount(summary) < 80 || wordCount(summary) > 200) {
    throw new Error("The episode brief did not pass the editorial length check.");
  }
  return { summary, prompts: selected };
}

export function validateAndRankPrompts(
  prompts: EpisodePrompt[],
  transcript: string,
  duration: number,
): EpisodePrompt[] {
  const transcriptKey = normalizedText(transcript);
  return prompts
    .filter((prompt) => prompt.passes_quality_gates)
    .filter((prompt) => Object.values(prompt.scores).every((value) => value >= 0.72 && value <= 1))
    .filter((prompt) => wordCount(prompt.question) >= 7 && wordCount(prompt.question) <= 36)
    .filter((prompt) => wordCount(prompt.expected_answer) >= 10 && wordCount(prompt.expected_answer) <= 110)
    .filter((prompt) => !isStockQuestion(prompt.question))
    .filter((prompt) => prompt.evidence.some((item) => {
      const quote = normalizedText(item.quote);
      return quote.length >= 30 && transcriptKey.includes(quote);
    }))
    .map((prompt) => ({
      ...prompt,
      time: evidenceTimestamp(prompt, transcriptKey, duration),
      question: ensureQuestion(normalizeWhitespace(prompt.question)),
      expected_answer: normalizeWhitespace(prompt.expected_answer),
    }))
    .filter((prompt) => answerAlignment(prompt) >= 0.22)
    .filter((prompt) => questionEvidenceAlignment(prompt) >= 0.25)
    .filter((prompt) => intersectionSize(tokens(prompt.question), tokens(prompt.expected_answer)) >= 1)
    .sort((left, right) => weightedScore(right) - weightedScore(left));
}

function selectDistinctPrompts(prompts: EpisodePrompt[], count: number): EpisodePrompt[] {
  const selected: EpisodePrompt[] = [];
  for (const prompt of prompts) {
    if (selected.length >= count) break;
    const distinct = selected.every((existing) => {
      return jaccard(tokens(existing.question), tokens(prompt.question)) < 0.68
        && jaccard(tokens(existing.expected_answer), tokens(prompt.expected_answer)) < 0.76;
    });
    if (distinct) selected.push(prompt);
  }
  return selected.sort((left, right) => left.time - right.time);
}

function transcriptChunks(transcript: string, duration: number): string[] {
  const words = transcript.split(/\s+/).filter(Boolean);
  const chunkSize = 3_200;
  const overlap = 180;
  const chunks: string[] = [];
  for (let start = 0; start < words.length; start += chunkSize - overlap) {
    const end = Math.min(words.length, start + chunkSize);
    const startSeconds = Math.round(duration * start / Math.max(words.length, 1));
    const endSeconds = Math.round(duration * end / Math.max(words.length, 1));
    chunks.push(`[[APPROX_SECONDS ${startSeconds}-${endSeconds}]]\n${words.slice(start, end).join(" ")}`);
    if (end === words.length) break;
  }
  return chunks;
}

async function mapConcurrent<T, R>(items: T[], concurrency: number, work: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  async function runner() {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      const item = items[index];
      if (item !== undefined) results[index] = await work(item, index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, () => runner()));
  return results;
}

function weightedScore(prompt: EpisodePrompt): number {
  const scores = prompt.scores;
  return scores.overall * 0.30
    + scores.importance_to_listener * 0.25
    + scores.episode_specificity * 0.15
    + scores.answer_alignment * 0.15
    + scores.grounding * 0.15;
}

function answerAlignment(prompt: EpisodePrompt): number {
  const evidenceTokens = tokens(prompt.evidence.map((item) => item.quote).join(" "));
  const answerTokens = tokens(prompt.expected_answer);
  if (answerTokens.size === 0) return 0;
  return intersectionSize(evidenceTokens, answerTokens) / answerTokens.size;
}

function questionEvidenceAlignment(prompt: EpisodePrompt): number {
  const evidenceTokens = tokens(prompt.evidence.map((item) => item.quote).join(" "));
  const questionTokens = tokens(prompt.question);
  if (questionTokens.size === 0) return 0;
  return intersectionSize(evidenceTokens, questionTokens) / Math.min(questionTokens.size, 6);
}

function evidenceTimestamp(prompt: EpisodePrompt, normalizedTranscript: string, duration: number): number {
  for (const item of prompt.evidence) {
    const quote = normalizedText(item.quote);
    const index = normalizedTranscript.indexOf(quote);
    if (index >= 0) {
      return Math.min(Math.max(duration * index / Math.max(normalizedTranscript.length, 1), 0), Math.max(duration, 1));
    }
  }
  return Number.isFinite(prompt.time) ? Math.min(Math.max(prompt.time, 0), Math.max(duration, 1)) : 0;
}

function isStockQuestion(question: string): boolean {
  const value = normalizedText(question);
  return [
    "what is the main idea", "summarize the episode", "what did they talk about",
    "according to the speaker", "what does the speaker say about", "what should listeners take away",
    "do you agree", "what do you think", "in your opinion", "how would you apply",
  ].some((phrase) => value.includes(phrase));
}

function ensureQuestion(value: string): string {
  if (!value) return value;
  const capitalized = value[0]?.toUpperCase() + value.slice(1);
  return capitalized.endsWith("?") ? capitalized : `${capitalized}?`;
}

function tokens(value: string): Set<string> {
  const ignored = new Set(["about", "after", "again", "because", "could", "from", "have", "into", "podcast", "speaker", "that", "their", "there", "these", "they", "this", "those", "what", "when", "where", "which", "while", "with", "would"]);
  return new Set(normalizedText(value).split(" ").filter((word) => word.length >= 4 && !ignored.has(word)));
}

function jaccard(left: Set<string>, right: Set<string>): number {
  if (left.size === 0 || right.size === 0) return 0;
  const intersection = intersectionSize(left, right);
  return intersection / (left.size + right.size - intersection);
}

function intersectionSize(left: Set<string>, right: Set<string>): number {
  let count = 0;
  for (const item of left) if (right.has(item)) count += 1;
  return count;
}

function wordCount(value: string): number {
  return value.trim().split(/\s+/).filter(Boolean).length;
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function normalizedText(value: string): string {
  return normalizeWhitespace(value.toLowerCase().replace(/[^\p{L}\p{N}' ]/gu, " "));
}
