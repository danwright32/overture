import { describe, it, expect } from "vitest";
import { isBlockedDate } from "./blockedDates";

describe("isBlockedDate", () => {
  it("is true when the ISO date is in the blocked set", () => {
    expect(isBlockedDate("2026-05-16", new Set(["2026-05-16"]))).toBe(true);
  });
  it("is false when the date is not blocked", () => {
    expect(isBlockedDate("2026-05-17", new Set(["2026-05-16"]))).toBe(false);
  });
  it("is false for a null date", () => {
    expect(isBlockedDate(null, new Set(["2026-05-16"]))).toBe(false);
  });
});
