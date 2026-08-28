import { describe, expect, it } from "vitest";
import type { AppConfig } from "../src/config.js";
import { decryptProviderCredential, encryptProviderCredential } from "../src/providerCredential.js";

const config = {
  providerCredentialEncryptionKey: "ab".repeat(32),
} as AppConfig;

describe("provider credential encryption", () => {
  it("round trips without storing the plaintext key", () => {
    const key = "sk-or-v1-listener-funded-test-key";
    const encrypted = encryptProviderCredential(key, config);
    expect(encrypted).not.toContain(key);
    expect(decryptProviderCredential(encrypted, config)).toBe(key);
  });

  it("rejects tampered ciphertext", () => {
    const encrypted = encryptProviderCredential("sk-or-v1-test", config);
    expect(() => decryptProviderCredential(`${encrypted}x`, config)).toThrow();
  });
});
