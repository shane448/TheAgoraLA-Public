import { describe, expect, it } from "vitest";
import { validateAndRankPrompts, type EpisodePrompt } from "../src/promptPipeline.js";

const evidence = "The host argues that attention is a form of respect because it allows another person's reasoning to change your mind.";
const transcript = `${evidence} Later, the guest distinguishes passive hearing from active listening by requiring the listener to reconstruct the argument before responding.`;

function prompt(overrides: Partial<EpisodePrompt> = {}): EpisodePrompt {
  return {
    time: 45,
    question: "Why does the host describe attention as a form of respect?",
    expected_answer: "Because genuine attention lets another person's reasoning affect and potentially change the listener's own view.",
    evidence: [{ quote: evidence, start_seconds: 30, end_seconds: 50 }],
    scores: {
      overall: 0.91,
      importance_to_listener: 0.9,
      episode_specificity: 0.88,
      answer_alignment: 0.92,
      grounding: 0.95,
    },
    passes_quality_gates: true,
    ...overrides,
  };
}

describe("prompt quality gates", () => {
  it("keeps an episode-specific question with exact transcript evidence", () => {
    expect(validateAndRankPrompts([prompt()], transcript, 120)).toHaveLength(1);
  });

  it("rejects stock questions even when the model marks them as passing", () => {
    const result = validateAndRankPrompts([prompt({ question: "What is the main idea of this episode?" })], transcript, 120);
    expect(result).toHaveLength(0);
  });

  it("rejects evidence that does not occur in the transcript", () => {
    const result = validateAndRankPrompts([
      prompt({ evidence: [{ quote: "A fabricated quote that does not occur anywhere in the supplied podcast transcript.", start_seconds: 30, end_seconds: 50 }] }),
    ], transcript, 120);
    expect(result).toHaveLength(0);
  });

  it("rejects an expected answer that is unrelated to the evidence", () => {
    const result = validateAndRankPrompts([
      prompt({ expected_answer: "The episode recommends buying specialized running shoes before beginning marathon training." }),
    ], transcript, 120);
    expect(result).toHaveLength(0);
  });
});
