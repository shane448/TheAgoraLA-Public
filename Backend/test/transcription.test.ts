import { describe, expect, it } from "vitest";
import { isPrivateAddress } from "../src/transcription.js";

describe("cloud audio network safety", () => {
  it("blocks private IPv4 and IPv4-mapped IPv6 destinations", () => {
    expect(isPrivateAddress("127.0.0.1")).toBe(true);
    expect(isPrivateAddress("10.2.3.4")).toBe(true);
    expect(isPrivateAddress("192.168.1.20")).toBe(true);
    expect(isPrivateAddress("::ffff:127.0.0.1")).toBe(true);
    expect(isPrivateAddress("::ffff:10.2.3.4")).toBe(true);
    expect(isPrivateAddress("::ffff:192.168.1.20")).toBe(true);
  });

  it("allows ordinary public addresses", () => {
    expect(isPrivateAddress("8.8.8.8")).toBe(false);
    expect(isPrivateAddress("2606:4700:4700::1111")).toBe(false);
  });

  it("blocks local and multicast IPv6 destinations", () => {
    expect(isPrivateAddress("::1")).toBe(true);
    expect(isPrivateAddress("fc00::1")).toBe(true);
    expect(isPrivateAddress("fe80::1")).toBe(true);
    expect(isPrivateAddress("ff02::1")).toBe(true);
  });
});
