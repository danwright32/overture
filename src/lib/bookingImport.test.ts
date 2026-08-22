import { describe, it, expect } from "vitest";
import {
  parseShootDate,
  mapBookingRow,
  parseBookingCsv,
  appStatus,
  appHistoryRecords,
} from "./bookingImport";

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

describe("appStatus (booking row -> app ranking vocabulary)", () => {
  const base = {
    "Name of Group": "Some Group",
    "Date of shoot": "",
    Email: "",
    Venue: "",
    "First Contact": "Cold Email (Me to Them)",
    "Type of Contact": "Direct Email",
    Status: "No Response",
  };
  const statusFor = (over: Record<string, string>) =>
    appStatus(mapBookingRow({ ...base, ...over }));

  it("maps Booked to booked", () => {
    expect(statusFor({ Status: "Booked" })).toBe("booked");
  });

  it("maps DNC to dnc", () => {
    expect(statusFor({ Status: "DNC" })).toBe("dnc");
  });

  it("maps 'I Declined' to declined", () => {
    expect(statusFor({ Status: "I Declined" })).toBe("declined");
  });

  it("maps a Lost row with no reason to lost_soft (the open-door default)", () => {
    expect(statusFor({ Status: "Lost" })).toBe("lost_soft");
  });

  it("imports a Lost row whose reason says hard as lost_hard", () => {
    expect(statusFor({ Status: "Lost", "Lost reason": "Hard no, won't book us" })).toBe("lost_hard");
  });

  it("imports a Lost row whose reason says never as lost_hard", () => {
    expect(statusFor({ Status: "Lost", "Lost reason": "they said never again" })).toBe("lost_hard");
  });

  it("imports a Lost row with a blank reason as lost_soft", () => {
    expect(statusFor({ Status: "Lost", "Lost reason": "" })).toBe("lost_soft");
  });

  it("keeps a warm first contact above a hard-lost reason", () => {
    expect(
      statusFor({ "First Contact": "Warm Email (Me to Them)", Status: "Lost", "Lost reason": "hard" }),
    ).toBe("warm");
  });

  it("treats a warm first contact as warm even when that thread got no response", () => {
    expect(statusFor({ "First Contact": "Warm Email (Me to Them)", Status: "No Response" })).toBe(
      "warm",
    );
  });

  it("lets a warm relationship beat a lost outcome", () => {
    expect(statusFor({ "First Contact": "Warm Email (Them to Me)", Status: "Lost" })).toBe("warm");
  });

  it("keeps Booked above a warm first contact", () => {
    expect(statusFor({ "First Contact": "Warm Email (Them to Me)", Status: "Booked" })).toBe(
      "booked",
    );
  });

  it("drops a cold pitch that got silence (neutral, no record)", () => {
    expect(statusFor({ "First Contact": "Cold Email (Me to Them)", Status: "No Response" })).toBeNull();
  });

  it("does not treat a mislabeled cold 'them to me' as warm", () => {
    expect(statusFor({ "First Contact": "Cold Email (Them to Me)", Status: "Lost" })).toBe(
      "lost_soft",
    );
  });
});

describe("appHistoryRecords", () => {
  it("maps rows to {groupName, status} and drops neutral cold ones", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      "Booked Choir,,,,Cold Email (Me to Them),Direct Email,Booked\n" +
      "Silent Org,,,,Cold Email (Me to Them),Direct Email,No Response\n" +
      "Warm Lead,,,,Warm Email (Them to Me),Direct Email,No Response\n";
    const records = appHistoryRecords(parseBookingCsv(csv));
    expect(records).toEqual([
      { groupName: "Booked Choir", status: "booked" },
      { groupName: "Warm Lead", status: "warm" },
    ]);
  });

  // #762: the CSV's Email column was parsed and then thrown away on the way to the app, so a
  // performer matched through past outreach (rather than through the Downbeat client list) had no
  // address to corroborate against. That is the branch most exposed to matching the wrong person
  // with the same name, since the booking history is older and broader than the client list.
  it("carries the email through, so a performer match can be corroborated", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      "Toma Reyes,,toma@example.com,,Cold Email (Me to Them),Direct Email,Booked\n";
    expect(appHistoryRecords(parseBookingCsv(csv))).toEqual([
      { groupName: "Toma Reyes", status: "booked", email: "toma@example.com" },
    ]);
  });

  // Absent stays absent rather than becoming an empty string: the app treats an empty address as
  // "no signal", and a key that is simply not there says the same thing without the ambiguity.
  it("omits the email key entirely when the cell is blank", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      "Booked Choir,,,,Cold Email (Me to Them),Direct Email,Booked\n";
    const records = appHistoryRecords(parseBookingCsv(csv));
    expect(records[0]).toEqual({ groupName: "Booked Choir", status: "booked" });
    expect("email" in records[0]).toBe(false);
  });

  // The CSV really does carry two-email cells (the parser's own header comment says so).
  it("keeps a two-email cell intact for the app to split", () => {
    const csv =
      "Name of Group,Date of shoot,Email,Venue,First Contact,Type of Contact,Status\n" +
      '"Duo Act",,"a@example.com, b@example.com",,Cold Email (Me to Them),Direct Email,Booked\n';
    expect(appHistoryRecords(parseBookingCsv(csv))[0].email).toBe(
      "a@example.com, b@example.com",
    );
  });
});
