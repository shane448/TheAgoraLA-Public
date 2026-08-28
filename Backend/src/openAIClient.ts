import { createReadStream } from "node:fs";
import OpenAI from "openai";
import type { AppConfig } from "./config.js";

export class AgoraOpenAI {
  private readonly client?: OpenAI;

  constructor(private readonly config: AppConfig, apiKey?: string, baseURL?: string) {
    const key = apiKey ?? config.openAIAPIKey;
    if (key) this.client = new OpenAI({ apiKey: key, baseURL });
  }

  async structured<T>(options: {
    model: string;
    instructions: string;
    input: string;
    schemaName: string;
    schema: Record<string, unknown>;
    safetyID: string;
    effort?: "low" | "medium" | "high";
  }): Promise<T> {
    const response = await this.requiredClient().responses.create({
      model: options.model,
      instructions: options.instructions,
      input: options.input,
      reasoning: { effort: options.effort ?? "medium" },
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: options.schemaName,
          strict: true,
          schema: options.schema,
        },
      },
      safety_identifier: options.safetyID,
      store: false,
    });
    const content = response.output_text.trim();
    if (!content) throw new Error("OpenAI returned an empty structured response.");
    return JSON.parse(content) as T;
  }

  async transcribe(filePath: string): Promise<string> {
    const result = await this.requiredClient().audio.transcriptions.create({
      file: createReadStream(filePath),
      model: this.config.models.transcription,
      response_format: "json",
    });
    const text = typeof result === "string" ? result : String((result as { text?: string }).text ?? "");
    return text.trim();
  }

  private requiredClient(): OpenAI {
    if (!this.client) throw new Error("No AI provider is configured for this request.");
    return this.client;
  }
}
