import { describe, it, expect } from "vitest";
import { parseDownbeatExport } from "./downbeatBridge";

const sample = JSON.stringify({
  version: 1,
  exportedAt: "2026-06-22T15:00:00Z",
  clients: [
    {
      id: "c1",
      displayName: "Every Voice Choirs",
      shortName: "Every Voice",
      email: "a@b.org",
      contractEmail: "a@b.org",
      phoneNumber: null,
      isTaxExempt: false,
      hasLeftReview: true,
      specialBehaviors: [],
      notes: null,
      hostingSite: "pixieset",
    },
  ],
  venues: [
    {
      id: "v1",
      name: "Merkin Hall",
      address: "129 W 67th St",
      editingProfile: "default",
      specialBehaviors: [],
      staffNotificationEmails: [],
      notes: null,
    },
  ],
});

describe("parseDownbeatExport", () => {
  it("parses clients and venues from a version-1 envelope", () => {
    const out = parseDownbeatExport(sample);
    expect(out.clients).toHaveLength(1);
    expect(out.clients[0].displayName).toBe("Every Voice Choirs");
    expect(out.venues[0].name).toBe("Merkin Hall");
  });

  it("defaults missing clients/venues arrays to empty", () => {
    const out = parseDownbeatExport(JSON.stringify({ version: 1 }));
    expect(out.clients).toEqual([]);
    expect(out.venues).toEqual([]);
  });

  it("treats a version-1 envelope as having no blocked dates", () => {
    const out = parseDownbeatExport(sample);
    expect(out.blockedDates).toEqual(new Set());
  });

  it("parses blockedDates from a version-2 envelope", () => {
    const out = parseDownbeatExport(
      JSON.stringify({
        version: 2,
        clients: [],
        venues: [],
        blockedDates: ["2026-07-04", "2026-07-05"],
      }),
    );
    expect(out.blockedDates).toEqual(new Set(["2026-07-04", "2026-07-05"]));
  });

  it("defaults a version-2 envelope with no blockedDates to an empty set", () => {
    const out = parseDownbeatExport(
      JSON.stringify({ version: 2, clients: [], venues: [] }),
    );
    expect(out.blockedDates).toEqual(new Set());
  });

  it("throws on an unsupported version", () => {
    expect(() => parseDownbeatExport(JSON.stringify({ version: 3 }))).toThrow(
      /unsupported downbeat export version/i,
    );
  });
});
