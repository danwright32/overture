import { describe, it, expect } from "vitest";
import { groupIntoRuns } from "./runGrouping";

function row(groupName: string, performanceDate: string | null, venue: string | null = "The Joyce", url = `u-${performanceDate}`) {
  return { groupName, venue, performanceDate, sourceListingUrl: url, fitScore: 9 };
}

describe("groupIntoRuns", () => {
  it("merges consecutive same-group+venue nights into one opening row with a range", () => {
    const out = groupIntoRuns([row("Mark Morris", "2026-07-14"), row("Mark Morris", "2026-07-15"), row("Mark Morris", "2026-07-16")]);
    expect(out).toHaveLength(1);
    expect(out[0].performanceDate).toBe("2026-07-14");
    expect(out[0].runEndDate).toBe("2026-07-16");
    expect(out[0].runSourceURLs.sort()).toEqual(["u-2026-07-14", "u-2026-07-15", "u-2026-07-16"]);
    expect(out[0].partOfRelatedRun).toBe(false);
  });

  it("chains across up to 2 dark days but splits on a larger gap", () => {
    const out = groupIntoRuns([row("X", "2026-07-01"), row("X", "2026-07-04"), row("X", "2026-07-20")]);
    expect(out).toHaveLength(2);
    expect(out[0].performanceDate).toBe("2026-07-01");
    expect(out[0].runEndDate).toBe("2026-07-04");
    expect(out[1].performanceDate).toBe("2026-07-20");
    expect(out[1].runEndDate).toBeNull();
  });

  it("flags two separate runs of the same group+venue as related", () => {
    const out = groupIntoRuns([row("Y", "2026-07-01"), row("Y", "2026-07-20")]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => r.partOfRelatedRun)).toBe(true);
  });

  it("does not merge different venues", () => {
    const out = groupIntoRuns([row("Z", "2026-07-01", "Hall A"), row("Z", "2026-07-02", "Hall B")]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => !r.partOfRelatedRun)).toBe(true);
  });

  it("leaves a single night with a null runEndDate and its own url", () => {
    const out = groupIntoRuns([row("Solo", "2026-07-01")]);
    expect(out[0].runEndDate).toBeNull();
    expect(out[0].runSourceURLs).toEqual(["u-2026-07-01"]);
  });

  it("passes undated rows through unmerged", () => {
    const out = groupIntoRuns([row("Undated", null), row("Undated", null)]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => r.runEndDate === null && !r.partOfRelatedRun)).toBe(true);
  });
});
