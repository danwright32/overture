import { describe, it, expect } from "vitest";
import { resolveVenue } from "./venueResolve";
import type { DownbeatVenue } from "./downbeatBridge";

function venue(over: Partial<DownbeatVenue> = {}): DownbeatVenue {
  return {
    id: "v1",
    name: "Merkin Hall",
    address: "129 W 67th St",
    editingProfile: null,
    specialBehaviors: [],
    staffNotificationEmails: [],
    notes: null,
    ...over,
  };
}

describe("resolveVenue", () => {
  it("returns the venue whose name matches, ignoring case and punctuation", () => {
    expect(resolveVenue("merkin hall", [venue()])?.id).toBe("v1");
  });
  it("returns null when no venue matches", () => {
    expect(resolveVenue("Carnegie Hall", [venue()])).toBeNull();
  });
  it("returns null for a missing venue name", () => {
    expect(resolveVenue(null, [venue()])).toBeNull();
  });
});
