import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseDownbeatExport } from "./downbeatBridge";

// Shared cross-language contract fixtures (#113). The SAME committed JSON files are decoded
// here and by mac/OvertureTests/DownbeatExportContractTests.swift, and both assert the same
// logical result. When the Downbeat export format changes, a reader that hasn't caught up
// fails its test instead of silently treating clients as cold in production (the #109 trap).
const fixture = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../fixtures/downbeat-export/${name}`, import.meta.url)),
    "utf8",
  );

describe("Downbeat export contract fixtures", () => {
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
