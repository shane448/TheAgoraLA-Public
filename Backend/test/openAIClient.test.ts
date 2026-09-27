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
    }), { signal: undefined });
  });

  it("does not start another billed request after cancellation", async () => {
    const controller = new AbortController();
    controller.abort();
    const client = new AgoraOpenAI({ models: { transcription: "test" } } as AppConfig, "test-key", undefined, controller.signal);
    await expect(client.transcribe("/dev/null")).rejects.toThrow();
    expect(mocks.transcribe).not.toHaveBeenCalled();
  });

  it("passes cancellation to an in-flight provider request", async () => {
    const controller = new AbortController();
    mocks.transcribe.mockResolvedValue({ text: "Transcript" });
    const client = new AgoraOpenAI({ models: { transcription: "test" } } as AppConfig, "test-key", undefined, controller.signal);
    await client.transcribe("/dev/null");
    expect(mocks.transcribe.mock.calls[0]?.[1]).toEqual({ signal: controller.signal });
  });
});
