import { describe, it, expect } from "vitest";
import { parseLocalHistory, loadLocalHistory } from "./localHistory";

describe("parseLocalHistory", () => {
  it("maps the app's camelCase groupName to the snake_case the matcher reads", () => {
    const out = parseLocalHistory(
      JSON.stringify([{ groupName: "Larchmont Music Academy", status: "Booked" }]),
    );
    expect(out).toEqual([
      { group_name: "Larchmont Music Academy", status: "Booked" },
    ]);
  });

  it("preserves a null status", () => {
    const out = parseLocalHistory(
      JSON.stringify([{ groupName: "Some Group", status: null }]),
    );
    expect(out[0].status).toBeNull();
  });

  it("returns an empty array for an empty file", () => {
    expect(parseLocalHistory("[]")).toEqual([]);
  });
});

describe("loadLocalHistory", () => {
  it("returns an empty array when the history file is absent", () => {
    expect(loadLocalHistory("/no/such/overture-history.json")).toEqual([]);
  });
});
