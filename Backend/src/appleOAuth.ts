import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { importPKCS8, SignJWT } from "jose";
import type { AppConfig } from "./config.js";

interface AppleTokenResponse {
  access_token?: string;
  refresh_token?: string;
  error?: string;
}

export async function exchangeAppleAuthorizationCode(code: string, config: AppConfig): Promise<string> {
  const response = await appleTokenRequest(new URLSearchParams({
    client_id: appleClientID(config),
    client_secret: await appleClientSecret(config),
    code,
    grant_type: "authorization_code",
  }));
  if (!response.refresh_token) {
    throw new Error("Apple did not return a refresh token for this account.");
  }
  return response.refresh_token;
}

export async function revokeAppleRefreshToken(refreshToken: string, config: AppConfig): Promise<void> {
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: appleClientID(config),
      client_secret: await appleClientSecret(config),
      token: refreshToken,
      token_type_hint: "refresh_token",
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) {
    throw new Error(`Apple token revocation returned HTTP ${response.status}.`);
  }
}

export function encryptAppleToken(token: string, config: AppConfig): string {
  const key = tokenEncryptionKey(config);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]).toString("base64");
}

export function decryptAppleToken(value: string, config: AppConfig): string {
  const payload = Buffer.from(value, "base64");
  if (payload.length < 29) throw new Error("The stored Apple token is invalid.");
  const iv = payload.subarray(0, 12);
  const tag = payload.subarray(12, 28);
  const encrypted = payload.subarray(28);
  const decipher = createDecipheriv("aes-256-gcm", tokenEncryptionKey(config), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString("utf8");
}

async function appleTokenRequest(body: URLSearchParams): Promise<AppleTokenResponse> {
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(20_000),
  });
  const payload = await response.json() as AppleTokenResponse;
  if (!response.ok) {
    throw new Error(`Apple authorization failed${payload.error ? `: ${payload.error}` : "."}`);
  }
  return payload;
}

async function appleClientSecret(config: AppConfig): Promise<string> {
  if (!config.appleTeamID || !config.appleKeyID || (!config.applePrivateKey && !config.applePrivateKeyPath)) {
    throw new Error("Apple server credentials are not configured.");
  }
  const privateKeyPEM = config.applePrivateKey
    ?? await readFile(config.applePrivateKeyPath as string, "utf8");
  const privateKey = await importPKCS8(privateKeyPEM, "ES256");
  const now = Math.floor(Date.now() / 1_000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.appleKeyID })
    .setIssuer(config.appleTeamID)
    .setAudience("https://appleid.apple.com")
    .setSubject(appleClientID(config))
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(privateKey);
}

function appleClientID(config: AppConfig): string {
  return config.appleClientID || config.appleBundleID;
}

function tokenEncryptionKey(config: AppConfig): Buffer {
  if (!config.appleTokenEncryptionKey) {
    throw new Error("APPLE_TOKEN_ENCRYPTION_KEY is not configured.");
  }
  return Buffer.from(config.appleTokenEncryptionKey, "hex");
}
