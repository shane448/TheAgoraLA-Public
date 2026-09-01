import { describe, expect, it } from "vitest";
import { graciousScore } from "../src/gradingPolicy.js";

describe("gracious grading score floors", () => {
  it("keeps a correct answer in the A range even when the raw score is harsh", () => {
    expect(graciousScore(72, "correct")).toBe(92);
  });

  it("gives a ballpark answer high credit", () => {
    expect(graciousScore(68, "mostly_correct")).toBe(85);
  });

  it("gives relevant partial understanding meaningful credit", () => {
    expect(graciousScore(41, "partial")).toBe(60);
  });

  it("does not inflate an answer classified as incorrect", () => {
    expect(graciousScore(24, "incorrect")).toBe(24);
  });

  it("does not let a contradictory label and raw score produce an undeserved high grade", () => {
    expect(graciousScore(96, "incorrect")).toBe(59);
  });

  it("bounds all scores at 100", () => {
    expect(graciousScore(120, "correct")).toBe(100);
  });
});
