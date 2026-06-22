import { describe, it, expect } from "vitest";
import { parseShootDate, mapBookingRow, parseBookingCsv } from "./bookingImport";

describe("parseShootDate", () => {
  it("converts M/D/YYYY to ISO YYYY-MM-DD, zero-padding month and day", () => {
    expect(parseShootDate("3/7/2026")).toBe("2026-03-07");
  });

  it("keeps already two-digit month and day", () => {
    expect(parseShootDate("12/25/2025")).toBe("2025-12-25");
  });

  it("trims surrounding whitespace", () => {
    expect(parseShootDate("  4/20/2026 ")).toBe("2026-04-20");
  });

  it("returns null for a blank cell", () => {
    expect(parseShootDate("")).toBeNull();
    expect(parseShootDate("   ")).toBeNull();
  });

  it("returns null for n/a in any case", () => {
    expect(parseShootDate("n/a")).toBeNull();
    expect(parseShootDate("N/A")).toBeNull();
  });

  it("returns null for an unparseable value", () => {
    expect(parseShootDate("Carnegie Hall")).toBeNull();
    expect(parseShootDate("13/40/2026")).toBeNull();
  });
});

const fullRow = {
  "Name of Group": "Larchmont Music Academy",
  "Date of shoot": "3/7/2026",
  Email: "frontdesk@larchmontmusicacademy.com",
  Venue: "Carnegie Hall",
  "First Contact": "Warm Email (Them to Me)",
  "Type of Contact": "Direct Email",
  Status: "Booked",
};

describe("mapBookingRow", () => {
  it("maps every CSV column to its history field", () => {
    const r = mapBookingRow(fullRow);
    expect(r.group_name).toBe("Larchmont Music Academy");
    expect(r.shoot_date).toBe("2026-03-07");
    expect(r.email).toBe("frontdesk@larchmontmusicacademy.com");
    expect(r.venue).toBe("Carnegie Hall");
    expect(r.first_contact).toBe("Warm Email (Them to Me)");
    expect(r.contact_type).toBe("Direct Email");
    expect(r.status).toBe("Booked");
  });

  it("turns blank optional cells into null", () => {
    const r = mapBookingRow({
      ...fullRow,
      "Date of shoot": "",
      Email: "",
      Venue: "   ",
      Status: "",
    });
    expect(r.shoot_date).toBeNull();
    expect(r.email).toBeNull();
    expect(r.venue).toBeNull();
    expect(r.status).toBeNull();
  });

  it("trims outer whitespace on group_name but keeps internal line breaks", () => {
    const r = mapBookingRow({
      ...fullRow,
      "Name of Group": "  Presented by Foo\nConcert Title  ",
    });
    expect(r.group_name).toBe("Presented by Foo\nConcert Title");
  });

  it("preserves the original row under raw_row", () => {
    const r = mapBookingRow(fullRow);
    expect(r.raw_row).toEqual(fullRow);
  });
});

describe("parseBookingCsv", () => {
  it("parses quoted multi-line cells with embedded commas correctly", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      '"Presented by Foo, Bar\nConcert Title",3/7/2026,info@foo.org,Carnegie Hall,Cold Email (Me to Them),Direct Email,Booked\n' +
      "Simple Group,,,,,,\n";
    const records = parseBookingCsv(csv);
    expect(records).toHaveLength(2);
    expect(records[0].group_name).toBe("Presented by Foo, Bar\nConcert Title");
    expect(records[0].shoot_date).toBe("2026-03-07");
    expect(records[0].email).toBe("info@foo.org");
    expect(records[1].group_name).toBe("Simple Group");
    expect(records[1].shoot_date).toBeNull();
    expect(records[1].venue).toBeNull();
  });

  it("skips rows with no group name", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      ",,,,,,\n" +
      "Real Group,,,,,,\n";
    const records = parseBookingCsv(csv);
    expect(records).toHaveLength(1);
    expect(records[0].group_name).toBe("Real Group");
  });
});
