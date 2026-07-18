// Deterministic checkers for the location rules in docs/scout-extract-runbook.md (#988).
//
// The scout-extract run is a Claude Code workflow, so these rules cannot be unit-tested against
// live model output on every PR (that costs a real run). What CAN be tested cheaply is whether a
// given extraction obeys the rules the runbook lays out as concrete input/output pairs. These
// functions encode two of those rules:
//
//   3a  `location` is reported VERBATIM: exactly the page's own words, never tidied, expanded,
//       abbreviated, or guessed. A confident wrong place is the one failure mode that can HIDE a
//       real show from Dan, which the runbook says is worse than reporting nothing.
//   3   A place-only string ("Baltimore, Maryland") is a location, never a venue. "never copy the
//       location into venue"; a city is not a room. A named place with its own proper name
//       ("Sakura Park") IS a venue (#1057).
//
// The checkers are pure so scoutExtractLocationGuard.test.ts can drive the checked-in corpus
// (fixtures/scout-extract-corpus/) both ways: the runbook's worked examples must pass, and the
// exact forbidden extractions the runbook calls out must be flagged.

export type ViolationKind = "location-not-verbatim" | "location-in-venue";

export interface Violation {
  kind: ViolationKind;
  detail: string;
}

export interface Extraction {
  venue: string | null;
  location: string | null;
}

// Normalized HTML (what the run reads) can reflow the page's whitespace: a newline where the page
// had a space, doubled spaces around a cell. Collapsing runs of whitespace lets a genuinely
// verbatim location still match, while any real edit to the words survives the collapse and is
// caught. Case is preserved on purpose: changing case is itself a normalization the runbook forbids.
function collapseWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

// 3a. The reported location must appear on the page exactly as written. If it does not, the run
// either edited it (tidied "Maryland" to "MD", added a country to "Amsterdam") or invented it
// (guessed a city from the org name); both land here, because neither survives as a verbatim slice
// of the page's own text. A null location is always allowed: the page simply did not say.
export function locationIsVerbatim(pageText: string, location: string | null): boolean {
  if (location === null) return true;
  return collapseWhitespace(pageText).includes(collapseWhitespace(location));
}

const VENUE_NOUN =
  /\b(hall|theatre|theater|center|centre|park|square|pier|church|synagogue|cathedral|chapel|club|room|house|stage|boathouse|cafe|gallery|museum|auditorium|studio|barge|plaza|garden|gardens|arena|stadium|library|academy|conservatory|university|college|lounge|pub|tavern|loft|factory|warehouse|works|mill|barn|field|commons|court|terrace|rooftop|hotel|inn|sanctuary|temple|ballroom|opera|playhouse|bandshell|amphitheater|amphitheatre|pavilion)\b/i;

// A bare US-state or country tail: "Baltimore, Maryland", "Harrogate, UK", "downtown Brooklyn, NY".
const US_STATE_NAMES = [
  "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Colorado", "Connecticut", "Delaware",
  "Florida", "Georgia", "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa", "Kansas", "Kentucky",
  "Louisiana", "Maine", "Maryland", "Massachusetts", "Michigan", "Minnesota", "Mississippi",
  "Missouri", "Montana", "Nebraska", "Nevada", "Ohio", "Oklahoma", "Oregon", "Pennsylvania",
  "Tennessee", "Texas", "Utah", "Vermont", "Virginia", "Washington", "Wisconsin", "Wyoming",
  "New Hampshire", "New Jersey", "New Mexico", "New York", "North Carolina", "North Dakota",
  "Rhode Island", "South Carolina", "South Dakota", "West Virginia",
];
const COUNTRY_OR_REGION_TAIL = ["UK", "USA", "US", "Germany", "Netherlands", "Norway", "France", "Canada"];

// The runbook's own test: could Dan's pitch name this place the way it names a hall? A proper-named
// place passes (it is a venue); a string that only says which city/state/country the show is in
// does not (it is a location, and belongs in `location`, never `venue`).
export function looksLikeBareLocation(value: string): boolean {
  const collapsed = collapseWhitespace(value);
  if (collapsed.length === 0) return false;
  // A proper-named place carries a venue-type noun ("Hall", "Park", "Square", "Centre"): it is a
  // venue even when a city trails it (an address artifact, #1030), so it is never a bare location.
  if (VENUE_NOUN.test(collapsed)) return false;

  const segments = collapsed.split(",").map((s) => s.trim());
  const tail = segments[segments.length - 1];
  if (segments.length >= 2) {
    if (/^[A-Z]{2}$/.test(tail)) return true; // "..., NY"
    if (US_STATE_NAMES.includes(tail)) return true; // "..., Maryland"
    if (COUNTRY_OR_REGION_TAIL.includes(tail)) return true; // "..., UK"
    // A trailing full address segment ending in a country, e.g. "12157 Germany".
    if (COUNTRY_OR_REGION_TAIL.some((c) => tail.endsWith(` ${c}`))) return true;
  }
  return false;
}

// 3. A place is not a room. venue must never carry a bare place-only string. The test is the
// venue string alone: a named place ("Sakura Park") is allowed even when the location repeats it
// verbatim (#1057), so this deliberately does NOT flag on venue equalling location; only a venue
// that reads as a bare city/state/country counts.
export function venueHoldsALocation(extraction: Extraction): boolean {
  const { venue } = extraction;
  if (venue === null) return false;
  return looksLikeBareLocation(venue);
}

export function findViolations(pageText: string, extraction: Extraction): Violation[] {
  const found: Violation[] = [];
  if (!locationIsVerbatim(pageText, extraction.location)) {
    found.push({
      kind: "location-not-verbatim",
      detail: `location ${JSON.stringify(extraction.location)} is not a verbatim slice of the page (3a): it was tidied, expanded, or guessed`,
    });
  }
  if (venueHoldsALocation(extraction)) {
    found.push({
      kind: "location-in-venue",
      detail: `venue ${JSON.stringify(extraction.venue)} is a place, not a room (3): a city belongs in location, never venue`,
    });
  }
  return found;
}
