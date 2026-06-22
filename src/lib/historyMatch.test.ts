import { describe, it, expect } from "vitest";
import { matchRelationship } from "./historyMatch";
import type { DownbeatClient } from "./downbeatBridge";
import type { HistoryRecord } from "./bookingImport";

function client(over: Partial<DownbeatClient> = {}): DownbeatClient {
  return {
    id: "c1",
    displayName: "Every Voice Choirs",
    shortName: null,
    email: "",
    contractEmail: "",
    phoneNumber: null,
    isTaxExempt: null,
    hasLeftReview: false,
    specialBehaviors: [],
    notes: null,
    hostingSite: "pixieset",
    ...over,
  };
}
function hist(over: Partial<HistoryRecord> = {}): HistoryRecord {
  return {
    group_name: "Some Group",
    shoot_date: null,
    email: null,
    venue: null,
    first_contact: null,
    contact_type: null,
    status: "No Response",
    raw_row: {},
    ...over,
  };
}

describe("matchRelationship", () => {
  it("returns booked with the client id on a confident Downbeat client match", () => {
    const v = matchRelationship("Every Voice Choirs", [client()], []);
    expect(v.relationship).toBe("booked");
    expect(v.downbeatClientId).toBe("c1");
    expect(v.matchedClientName).toBe("Every Voice Choirs");
    expect(v.suppressed).toBe(false);
  });

  it("returns booked when only the CSV history has a confident Booked row", () => {
    const v = matchRelationship(
      "Larchmont Music Academy",
      [],
      [hist({ group_name: "Larchmont Music Academy", status: "Booked" })],
    );
    expect(v.relationship).toBe("booked");
    expect(v.downbeatClientId).toBeNull();
  });

  it("returns contacted on a confident history match that never booked", () => {
    const v = matchRelationship(
      "Royal Gala Concert",
      [],
      [hist({ group_name: "Royal Gala Concert", status: "No Response" })],
    );
    expect(v.relationship).toBe("contacted");
  });

  it("suppresses when a confident history match is DNC", () => {
    const v = matchRelationship(
      "Do Not Email Inc",
      [],
      [hist({ group_name: "Do Not Email Inc", status: "DNC" })],
    );
    expect(v.suppressed).toBe(true);
    expect(v.relationship).toBe("none");
  });

  it("returns none with a possible flag on a fuzzy client match", () => {
    const v = matchRelationship(
      "Royal Foundation Music Arts",
      [client({ id: "c9", displayName: "The Royal Music Arts" })],
      [],
    );
    expect(v.relationship).toBe("none");
    expect(v.possible).toEqual({
      source: "downbeat_client",
      ref: "c9",
      name: "The Royal Music Arts",
    });
  });

  it("returns none with no possible flag when nothing is close", () => {
    const v = matchRelationship("Manhattan Opera Guild", [client()], [hist()]);
    expect(v.relationship).toBe("none");
    expect(v.possible).toBeNull();
  });
});
