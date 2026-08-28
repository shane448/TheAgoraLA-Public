import { createHash } from "node:crypto";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import type { AppConfig } from "./config.js";

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export interface SessionClaims {
  userID: string;
}

export async function verifyAppleIdentityToken(
  identityToken: string,
  rawNonce: string,
  config: AppConfig,
): Promise<{ subject: string; email?: string }> {
  const { payload } = await jwtVerify(identityToken, appleKeys, {
    issuer: "https://appleid.apple.com",
    audience: config.appleBundleID,
  });
  const expectedNonce = createHash("sha256").update(rawNonce).digest("hex");
  if (payload.nonce !== expectedNonce || typeof payload.sub !== "string") {
    throw new Error("Apple sign-in nonce verification failed.");
  }
  return {
    subject: payload.sub,
    ...(typeof payload.email === "string" ? { email: payload.email } : {}),
  };
}

export async function createSessionToken(userID: string, config: AppConfig): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer("the-agora-la")
    .setAudience(config.appleBundleID)
    .setSubject(userID)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(new TextEncoder().encode(config.sessionSecret));
}

export async function verifySessionToken(token: string, config: AppConfig): Promise<SessionClaims> {
  const { payload } = await jwtVerify(token, new TextEncoder().encode(config.sessionSecret), {
    issuer: "the-agora-la",
    audience: config.appleBundleID,
  });
  if (typeof payload.sub !== "string") {
    throw new Error("Session is missing a user identifier.");
  }
  return { userID: payload.sub };
}
