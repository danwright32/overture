// #1908: the prep runbook's "Input / output (exact)" section is a SPEC of the handoff files, written
// in prose, sitting in a different language from the code that produces them. Nothing checked the two
// agreed, so they drifted: #1897 shipped PrepQueue v10 carrying `venueHistory` while the runbook's
// input spec still said version 9 and never named the field, even though §2 already carried the rule
// that reads it.
//
// This is worse than ordinary doc rot because the runbook IS the prompt that the Prep run executes.
// A spec that omits a field the payload carries, or names one it does not, is precisely the condition
// that makes the model supply the missing thing out of its own head (L27, and #1824's live instance,
// where a listing URL was handed over and never mentioned again and the draft invented the show).
//
// The extractors are pure so the checking lives in a test that runs in `pnpm test`, and therefore in
// CI, rather than in a script nobody remembers to run. They read the SWIFT SOURCE TEXT for the same
// reason docsCommands.ts reads package.json: the number and the field list are the artifacts that
// have to agree, and reading them is cheaper and more honest than mirroring them here by hand (L41).

/** The `PrepQueue` version the runbook's input spec says it expects, or null if the spec is unreadable. */
export function runbookQueueVersion(runbook: string): number | null {
  return matchedInt(runbook, /`PrepQueue`\s+version\s+`(\d+)`/);
}

/** The `PrepResults` version the runbook's output spec says it writes, or null if unreadable. */
export function runbookResultsVersion(runbook: string): number | null {
  return matchedInt(runbook, /`PrepResults`\s+version\s+`(\d+)`/);
}

/** `PrepQueueBuilder.version`, the version the app actually stamps on the file it writes. */
export function swiftQueueVersion(prepQueueSwift: string): number | null {
  return matchedInt(prepQueueSwift, /enum\s+PrepQueueBuilder\b[\s\S]*?static\s+let\s+version\s*=\s*(\d+)/);
}

/** `PrepResultsDecoder.supportedVersion`, the newest results file the app will read. */
export function swiftResultsSupportedVersion(prepResultsSwift: string): number | null {
  return matchedInt(prepResultsSwift, /static\s+let\s+supportedVersion\s*=\s*(\d+)/);
}

// The item fields the runbook enumerates, read from the enumeration ITSELF (`items[]` each with ...,
// up to its closing parenthesis) rather than from the whole bullet. The paragraphs below the list
// discuss most of those fields again, and the Write bullet names PrepResults' own fields; harvesting
// backticks from all of it would hold the item spec to names that belong to something else. Tolerant
// of rewrapping, because the runbook is prose that gets reflowed.
export function runbookItemFields(runbook: string): string[] {
  const list = runbook.match(/`items\[\]`\s+each\s+with([\s\S]*?)\)/);
  if (!list) return [];
  return [...new Set([...list[1].matchAll(/`([A-Za-z][A-Za-z0-9]*)`/g)].map((m) => m[1]))];
}

// Every stored property on `PrepQueueItem`. Read from the struct body only, so `PrepQueue`'s own
// run-level fields (`version`, `generatedAt`, `items`, `houses`) and `ShowListing`'s are not counted
// as item fields. A commented-out line cannot match: the pattern requires `var` to open the line.
export function swiftItemFields(prepQueueSwift: string): string[] {
  const body = prepQueueSwift.match(/struct\s+PrepQueueItem\b[^{]*\{([\s\S]*?)\n\}/);
  if (!body) return [];
  return [...new Set([...body[1].matchAll(/^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:/gm)].map((m) => m[1]))];
}

export interface ItemFieldDrift {
  /** Carried by the payload, absent from the runbook's list: the model is never told it exists. */
  missingFromRunbook: string[];
  /** Named by the runbook, absent from the payload: the model is invited to supply it itself. */
  namedButNotInPayload: string[];
}

export function compareItemFields(runbookFields: string[], swiftFields: string[]): ItemFieldDrift {
  const named = new Set(runbookFields);
  const carried = new Set(swiftFields);
  return {
    missingFromRunbook: swiftFields.filter((f) => !named.has(f)).sort(),
    namedButNotInPayload: runbookFields.filter((f) => !carried.has(f)).sort(),
  };
}

function matchedInt(text: string, pattern: RegExp): number | null {
  const found = text.match(pattern);
  return found ? Number.parseInt(found[1], 10) : null;
}
