import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppConfig } from "../src/config.js";

const mocks = vi.hoisted(() => ({ transcribe: vi.fn() }));

vi.mock("openai", () => ({
  default: class MockOpenAI {
    audio = { transcriptions: { create: mocks.transcribe } };
  },
}));

import { AgoraOpenAI } from "../src/openAIClient.js";

afterEach(() => vi.clearAllMocks());

describe("AgoraOpenAI transcription", () => {
  it("requests OpenRouter's supported JSON response format", async () => {
    mocks.transcribe.mockResolvedValue({ text: "A complete podcast transcript." });
    const config = {
      models: { transcription: "openai/gpt-4o-mini-transcribe" },
    } as AppConfig;
    const client = new AgoraOpenAI(config, "test-key", "https://openrouter.ai/api/v1");

    await expect(client.transcribe("/dev/null")).resolves.toBe("A complete podcast transcript.");
    expect(mocks.transcribe).toHaveBeenCalledWith(expect.objectContaining({
      model: "openai/gpt-4o-mini-transcribe",
      response_format: "json",
    }));
  });
});
