import { spawn } from "node:child_process";
import { lookup } from "node:dns/promises";
import { mkdtemp, open, readdir, rm, stat } from "node:fs/promises";
import { isIP } from "node:net";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import type { AppConfig } from "./config.js";
import type { AgoraOpenAI } from "./openAIClient.js";

export async function transcribeRemoteAudio(
  audioURL: string,
  openAI: AgoraOpenAI,
  config: AppConfig,
): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agora-audio-"));
  try {
    const downloaded = await downloadPublicAudio(audioURL, directory, config.maxAudioBytes);
    const fileStats = await stat(downloaded);
    let parts = [downloaded];
    if (fileStats.size > 24_000_000) {
      parts = await splitAudio(downloaded, directory);
    }
    const transcriptParts = await mapConcurrent(
      parts,
      config.transcriptionConcurrency,
      (part) => openAI.transcribe(part),
    );
    const transcript = transcriptParts.join(" ").replace(/\s+/g, " ").trim();
    if (transcript.split(/\s+/).length < 120) {
      throw new Error("The audio transcription was too short to analyze reliably.");
    }
    return transcript;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export async function downloadRemoteTranscript(
  input: string,
  declaredType?: string,
): Promise<string> {
  const maximumBytes = 25_000_000;
  let url = new URL(input);
  for (let redirect = 0; redirect <= 3; redirect += 1) {
    await assertPublicHTTPSURL(url);
    const response = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(60_000) });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("The transcript host returned an invalid redirect.");
      url = new URL(location, url);
      continue;
    }
    if (!response.ok) throw new Error(`The transcript host returned HTTP ${response.status}.`);
    const responseType = (response.headers.get("content-type") ?? "").toLowerCase();
    if (responseType.startsWith("audio/") || responseType.startsWith("video/")
      || responseType.startsWith("image/")) {
      throw new Error("The published transcript link did not resolve to readable text.");
    }
    const statedLength = Number(response.headers.get("content-length") ?? 0);
    if (statedLength > maximumBytes) throw new Error("The published transcript is larger than the server limit.");
    const data = await readResponseBytes(response, maximumBytes);
    const type = [declaredType, responseType, extname(url.pathname)]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    const transcript = normalizePublishedTranscript(data, type);
    if (transcript.split(/\s+/).filter(Boolean).length < 120) {
      throw new Error("The published transcript was too short to analyze reliably.");
    }
    return transcript;
  }
  throw new Error("The transcript URL redirected too many times.");
}

export function normalizePublishedTranscript(data: Uint8Array, type: string): string {
  const raw = Buffer.from(data).toString("utf8").replace(/^\uFEFF/, "");
  if (type.includes("json") || raw.trimStart().startsWith("{") || raw.trimStart().startsWith("[")) {
    try {
      const text = collectTranscriptText(JSON.parse(raw));
      if (text) return normalizeWhitespace(text);
    } catch {
      // Some feeds label plain transcript text as JSON; fall through to text parsing.
    }
  }
  if (type.includes("html") || /<html[\s>]/i.test(raw)) {
    return normalizeWhitespace(decodeHTMLEntities(raw
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " ")));
  }
  if (type.includes("vtt") || type.includes("srt") || raw.startsWith("WEBVTT") || raw.includes(" --> ")) {
    return normalizeWhitespace(raw
      .split(/\r?\n/)
      .filter((line) => !/^\s*(WEBVTT|NOTE|\d+)\s*$/.test(line))
      .filter((line) => !line.includes(" --> "))
      .join(" ")
      .replace(/<[^>]+>/g, " "));
  }
  return normalizeWhitespace(raw);
}

async function downloadPublicAudio(input: string, directory: string, maxBytes: number): Promise<string> {
  let url = new URL(input);
  for (let redirect = 0; redirect <= 3; redirect += 1) {
    await assertPublicHTTPSURL(url);
    const response = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(120_000) });
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) throw new Error("The audio host returned an invalid redirect.");
      url = new URL(location, url);
      continue;
    }
    if (!response.ok) throw new Error(`The audio host returned HTTP ${response.status}.`);
    const contentType = (response.headers.get("content-type") ?? "").toLowerCase();
    if (contentType.includes("text/html") || contentType.includes("application/json")
      || contentType.includes("mpegurl") || url.pathname.toLowerCase().endsWith(".m3u8")) {
      throw new Error("The podcast link did not resolve to a downloadable audio file.");
    }
    const statedLength = Number(response.headers.get("content-length") ?? 0);
    if (statedLength > maxBytes) throw new Error("This podcast audio file is larger than the server limit.");
    const suffix = safeExtension(url.pathname);
    const path = join(directory, `episode${suffix}`);
    await streamResponseToFile(response, path, maxBytes);
    return path;
  }
  throw new Error("The audio URL redirected too many times.");
}

async function streamResponseToFile(response: Response, path: string, maxBytes: number): Promise<void> {
  if (!response.body) throw new Error("The audio host returned an empty response.");
  const reader = response.body.getReader();
  const file = await open(path, "wx");
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel();
        throw new Error("This podcast audio file is larger than the server limit.");
      }
      await file.write(value);
    }
    if (totalBytes === 0) throw new Error("The audio host returned an empty response.");
  } finally {
    await file.close();
  }
}

async function readResponseBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  if (!response.body) throw new Error("The transcript host returned an empty response.");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      await reader.cancel();
      throw new Error("The published transcript is larger than the server limit.");
    }
    chunks.push(value);
  }
  if (totalBytes === 0) throw new Error("The transcript host returned an empty response.");
  const result = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

async function assertPublicHTTPSURL(url: URL): Promise<void> {
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password) {
    throw new Error("Only public HTTPS audio URLs are supported.");
  }
  const addresses = await lookup(url.hostname, { all: true, verbatim: true });
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new Error("The audio URL does not resolve to a public host.");
  }
}

export function isPrivateAddress(address: string): boolean {
  const normalized = address.toLowerCase();
  if (normalized.startsWith("::ffff:")) {
    return isPrivateAddress(normalized.slice("::ffff:".length));
  }
  if (isIP(address) === 4) {
    const [a = 0, b = 0] = address.split(".").map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  return normalized === "::1" || normalized === "::" || normalized.startsWith("fc")
    || normalized.startsWith("fd") || normalized.startsWith("fe80:") || normalized.startsWith("ff");
}

function safeExtension(path: string): string {
  const value = extname(path).toLowerCase();
  return [".mp3", ".m4a", ".mp4", ".aac", ".wav", ".flac", ".ogg", ".webm"].includes(value) ? value : ".mp3";
}

async function splitAudio(input: string, directory: string): Promise<string[]> {
  const outputPattern = join(directory, "segment-%03d.m4a");
  await runProcess("ffmpeg", [
    "-hide_banner", "-loglevel", "error", "-i", input,
    "-f", "segment", "-segment_time", "480", "-vn", "-c:a", "aac", "-b:a", "64k", outputPattern,
  ]);
  const parts = (await readdir(directory))
    .filter((name) => name.startsWith("segment-") && name.endsWith(".m4a"))
    .sort()
    .map((name) => join(directory, name));
  if (parts.length === 0) throw new Error("The server could not split this podcast for transcription.");
  return parts;
}

function runProcess(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let errorOutput = "";
    child.stderr.on("data", (chunk) => { errorOutput += String(chunk).slice(0, 2_000); });
    child.on("error", reject);
    child.on("close", (code) => code === 0 ? resolve() : reject(new Error(errorOutput || `${command} exited with ${code}.`)));
  });
}

async function mapConcurrent<T, R>(
  items: T[],
  concurrency: number,
  work: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  async function runner() {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      const item = items[index];
      if (item !== undefined) results[index] = await work(item, index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(Math.max(concurrency, 1), items.length) }, () => runner()));
  return results;
}

function collectTranscriptText(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(collectTranscriptText).filter(Boolean).join(" ");
  if (!value || typeof value !== "object") return "";
  const object = value as Record<string, unknown>;
  const preferredKeys = ["transcript", "body", "segments", "utterances", "results", "items", "text", "content"];
  for (const key of preferredKeys) {
    if (!(key in object)) continue;
    const result = collectTranscriptText(object[key]);
    if (result) return result;
  }
  return "";
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">");
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}
