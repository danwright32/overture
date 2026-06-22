import { describe, it, expect } from "vitest";
import {
  decideProspect,
  type DiscoveredEvent,
  type Classification,
} from "./assembleProspect";
import type { MatchVerdict } from "./historyMatch";

function event(over: Partial<DiscoveredEvent> = {}): DiscoveredEvent {
  return {
    group_name: "Every Voice Choirs",
    discipline: "choral",
    venue: "Merkin Hall",
    performance_date: "2026-05-16",
    source_listing_url: null,
    website_url: null,
    ...over,
  };
}
function classification(over: Partial<Classification> = {}): Classification {
  return {
    reachable: true,
    production: "self",
    profile: "strong",
    coverage: "likely_uncovered",
    fit_reason: "Self-produced choral concert at a reachable hall.",
    ...over,
  };
}
function verdict(over: Partial<MatchVerdict> = {}): MatchVerdict {
  return {
    relationship: "none",
    suppressed: false,
    downbeatClientId: null,
    matchedClientName: null,
    possible: null,
    ...over,
  };
}

describe("decideProspect", () => {
  it("skips a performance on a blocked date", () => {
    const d = decideProspect(
      event(),
      classification(),
      verdict(),
      new Set(["2026-05-16"]),
    );
    expect(d).toEqual({ kind: "skip", reason: "blocked" });
  });

  it("skips a suppressed (DNC) group", () => {
    const d = decideProspect(
      event(),
      classification(),
      verdict({ suppressed: true }),
      new Set(),
    );
    expect(d).toEqual({ kind: "skip", reason: "suppressed" });
  });

  it("skips an unreachable performance", () => {
    const d = decideProspect(
      event(),
      classification({ reachable: false }),
      verdict(),
      new Set(),
    );
    expect(d).toEqual({ kind: "skip", reason: "unreachable" });
  });

  it("builds a scored prospect row carrying the verdict", () => {
    const d = decideProspect(
      event(),
      classification(),
      verdict({
        relationship: "booked",
        downbeatClientId: "c1",
        matchedClientName: "Every Voice Choirs",
      }),
      new Set(),
    );
    expect(d.kind).toBe("prospect");
    if (d.kind !== "prospect") return;
    expect(d.row.prior_relationship).toBe("booked");
    expect(d.row.downbeat_client_id).toBe("c1");
    expect(d.row.tier).toBe("high");
    expect(d.row.fit_score).toBeGreaterThan(0);
    expect(d.row.status).toBe("new");
  });

  it("carries a possible match onto the row without scoring it", () => {
    const d = decideProspect(
      event(),
      classification({
        production: "unknown",
        profile: "neutral",
        coverage: "unknown",
      }),
      verdict({
        possible: { source: "downbeat_client", ref: "c9", name: "Royal Music" },
      }),
      new Set(),
    );
    if (d.kind !== "prospect") throw new Error("expected prospect");
    expect(d.row.possible_match_source).toBe("downbeat_client");
    expect(d.row.possible_match_ref).toBe("c9");
    expect(d.row.possible_match_name).toBe("Royal Music");
    expect(d.row.prior_relationship).toBe("none");
  });

  it("emits a null ref for a history possible match (history rows have no id)", () => {
    const d = decideProspect(
      event(),
      classification(),
      verdict({ possible: { source: "history", ref: "", name: "Old Lead" } }),
      new Set(),
    );
    if (d.kind !== "prospect") throw new Error("expected prospect");
    expect(d.row.possible_match_source).toBe("history");
    expect(d.row.possible_match_ref).toBeNull();
    expect(d.row.possible_match_name).toBe("Old Lead");
  });
});
