import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseDownbeatExport } from "./downbeatBridge";

// Shared cross-language contract fixtures (#113). The SAME committed JSON files are decoded
// here and by mac/OvertureTests/DownbeatExportContractTests.swift, and both assert the same
// logical result. When the Downbeat export format changes, a reader that hasn't caught up
// fails its test instead of silently treating clients as cold in production (the #109 trap).
const FIXTURE_DIR = new URL("../../fixtures/downbeat-export/", import.meta.url);
const fixture = (name: string) => readFileSync(new URL(name, FIXTURE_DIR), "utf8");
const fixtureFiles = readdirSync(fileURLToPath(FIXTURE_DIR)).filter((name) =>
  name.endsWith(".json"),
);

describe("Downbeat export contract fixtures", () => {
  // #491: enumerates whatever is actually committed, so a new fixture file with no matching
  // decode case fails here instead of silently shipping with zero coverage on this side.
  it("has at least one committed fixture file", () => {
    expect(fixtureFiles.length).toBeGreaterThan(0);
  });

  it.each(fixtureFiles)("decodes %s without throwing", (name) => {
    expect(() => parseDownbeatExport(fixture(name))).not.toThrow();
  });

  it("decodes the v2 fixture to the agreed logical shape", () => {
    const out = parseDownbeatExport(fixture("v2.json"));
    expect(out.clients).toHaveLength(2);
    expect(out.venues).toHaveLength(1);
    expect(out.bookings).toHaveLength(2);

    // Identity is keyed on clientId; displayName is a label only.
    expect(out.clients[0].id).toBe("11111111-1111-1111-1111-111111111111");
    expect(out.clients[0].displayName).toBe("Every Voice Choirs");
    // Minimal client: omitted optionals are absent.
    expect(out.clients[1].id).toBe("55555555-5555-5555-5555-555555555555");
    expect(out.clients[1].shortName ?? null).toBeNull();

    // Booking with a real venue, then the ad-hoc (venueId omitted) case.
    expect(out.bookings[0].venueId).toBe("33333333-3333-3333-3333-333333333333");
    expect(out.bookings[0].startDate).toBe("2026-03-10");
    expect(out.bookings[1].venueId).toBeUndefined();
    expect(out.bookings[1].venueName).toBe("Pop-up Loft");

    expect(out.blockedDates).toEqual(
      new Set(["2026-03-10", "2026-03-11", "2026-03-12", "2026-04-02"]),
    );
  });

  it("decodes the v1 fixture (no bookings/blockedDates) to the agreed logical shape", () => {
    const out = parseDownbeatExport(fixture("v1.json"));
    expect(out.clients).toHaveLength(1);
    expect(out.venues).toHaveLength(1);
    expect(out.bookings).toEqual([]);
    expect(out.blockedDates).toEqual(new Set());
  });
});
