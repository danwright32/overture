// Name matching for repeat-client detection. Calendar group names are messy
// (presenter + program title, often multi-line); these helpers normalize them
// and decide confident vs merely-possible matches. Precision is prioritized:
// only confident matches drive scoring, possibles are flagged for review.

// Drop a trailing program/subtitle after a clear separator (space-dash-space, en/em
// dash, or colon), keeping the presenter — but only when the presenter is >= 2 words,
// so a generic one-word prefix (e.g. "Jazz - ...") isn't collapsed. Booking-sheet names
// are "Presenter - Program"; the venue lists just the presenter, so this lets them match.
function stripProgramSubtitle(s: string): string {
  const m = s.match(/^(.*?)(?:\s[-–—]\s|:\s).+$/);
  if (!m) return s;
  const presenter = m[1].trim();
  return presenter.split(/\s+/).filter(Boolean).length >= 2 ? presenter : s;
}

// Isolate the org/presenter line from a messy, often multi-line entry. A "Presented by X"
// line names the org and can sit on any line (program title first or presenter first), so
// prefer it; otherwise fall back to the first line. Mirrors the app's GroupNameMatch.orgLine.
function orgLine(name: string): string {
  const lines = name.split("\n").map((l) => l.trim());
  return lines.find((l) => /^presented by\s+/i.test(l)) ?? lines[0] ?? "";
}

export function normalizeGroupName(name: string): string {
  const presenter = stripProgramSubtitle(orgLine(name).replace(/^\s*presented by\s+/i, ""));
  return presenter
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokens(name: string): string[] {
  return normalizeGroupName(name).split(" ").filter(Boolean);
}

// True when `short` appears as a contiguous run of whole tokens inside `long`.
function containsTokenRun(long: string[], short: string[]): boolean {
  for (let i = 0; i + short.length <= long.length; i += 1) {
    let matched = true;
    for (let j = 0; j < short.length; j += 1) {
      if (long[i + j] !== short[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

// A confident match is exact, or one name's whole-token sequence sits contiguously
// inside the other AND makes up a meaningful fraction of it. The fraction guard
// stops a short name (e.g. "New York") confidently matching an unrelated larger
// one ("New York Theatre Ballet") — the false positive we must avoid.
const MIN_CONTAINMENT_FRACTION = 0.6;

export function isConfidentMatch(a: string, b: string): boolean {
  const ta = tokens(a);
  const tb = tokens(b);
  if (ta.length === 0 || tb.length === 0) return false;
  if (ta.join(" ") === tb.join(" ")) return true;

  const [short, long] = ta.length <= tb.length ? [ta, tb] : [tb, ta];
  if (short.length < 2) return false;
  if (short.length / long.length < MIN_CONTAINMENT_FRACTION) return false;
  return containsTokenRun(long, short);
}

export function isPossibleMatch(a: string, b: string): boolean {
  if (isConfidentMatch(a, b)) return false;
  const ta = new Set(tokens(a));
  const tb = new Set(tokens(b));
  if (ta.size === 0 || tb.size === 0) return false;
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared += 1;
  const union = new Set([...ta, ...tb]).size;
  return shared / union >= 0.5;
}
