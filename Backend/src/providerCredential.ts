import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import type { AppConfig } from "./config.js";

export function encryptProviderCredential(value: string, config: AppConfig): string {
  const key = credentialKey(config);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, encrypted].map((part) => part.toString("base64url")).join(".");
}

export function decryptProviderCredential(value: string, config: AppConfig): string {
  const [ivValue, tagValue, encryptedValue] = value.split(".");
  if (!ivValue || !tagValue || !encryptedValue) throw new Error("The provider credential is invalid.");
  const decipher = createDecipheriv("aes-256-gcm", credentialKey(config), Buffer.from(ivValue, "base64url"));
  decipher.setAuthTag(Buffer.from(tagValue, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(encryptedValue, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}

function credentialKey(config: AppConfig): Buffer {
  return Buffer.from(config.providerCredentialEncryptionKey, "hex");
}
