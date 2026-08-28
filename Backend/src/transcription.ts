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
    const transcriptParts: string[] = [];
    for (const part of parts) {
      const text = await openAI.transcribe(part);
      if (text) transcriptParts.push(text);
    }
    const transcript = transcriptParts.join(" ").replace(/\s+/g, " ").trim();
    if (transcript.split(/\s+/).length < 120) {
      throw new Error("The audio transcription was too short to analyze reliably.");
    }
    return transcript;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
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

async function assertPublicHTTPSURL(url: URL): Promise<void> {
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password) {
    throw new Error("Only public HTTPS audio URLs are supported.");
  }
  const addresses = await lookup(url.hostname, { all: true, verbatim: true });
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new Error("The audio URL does not resolve to a public host.");
  }
}

function isPrivateAddress(address: string): boolean {
  if (isIP(address) === 4) {
    const [a = 0, b = 0] = address.split(".").map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  const normalized = address.toLowerCase();
  return normalized === "::1" || normalized === "::" || normalized.startsWith("fc")
    || normalized.startsWith("fd") || normalized.startsWith("fe80:") || normalized.startsWith("::ffff:127.");
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
