import { describe, it, expect } from "vitest";
import {
  normalizeGroupName,
  isConfidentMatch,
  isPossibleMatch,
} from "./groupNameMatch";

describe("normalizeGroupName", () => {
  it("lowercases, strips 'Presented by', drops the title line, removes punctuation", () => {
    expect(
      normalizeGroupName("Presented by Every Voice Choirs\nSpring Concert"),
    ).toBe("every voice choirs");
  });
  it("collapses whitespace and trims", () => {
    expect(normalizeGroupName("  The   Royal   Gala  ")).toBe("the royal gala");
  });
});

describe("isConfidentMatch", () => {
  it("matches identical normalized names", () => {
    expect(isConfidentMatch("Every Voice Choirs", "every voice choirs")).toBe(
      true,
    );
  });
  it("matches when one name contains the other (>= 2 tokens)", () => {
    expect(
      isConfidentMatch("Every Voice Choirs - Spring Concert", "Every Voice Choirs"),
    ).toBe(true);
  });
  it("does not match on a single shared token", () => {
    expect(isConfidentMatch("Music Academy", "Larchmont Music")).toBe(false);
  });
});

describe("isPossibleMatch", () => {
  it("flags strong token overlap that is not a confident match", () => {
    expect(
      isPossibleMatch("Royal Foundation Music Arts", "The Royal Music Arts"),
    ).toBe(true);
  });
  it("is false for a confident match (handled separately)", () => {
    expect(isPossibleMatch("Every Voice Choirs", "Every Voice Choirs")).toBe(
      false,
    );
  });
  it("is false for weak overlap", () => {
    expect(isPossibleMatch("Brooklyn Youth Chorus", "Manhattan Opera Guild")).toBe(
      false,
    );
  });
});
