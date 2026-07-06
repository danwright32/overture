// Lightweight structural checks for the 7 JSON handoff contracts where one side is a Claude
// Code workflow, not code (docs/contracts.md's "CI coverage" section): scout-refine, prep-queue,
// prep-results, reply-classify, voice-feedback. Full behavioral testing of the workflow side
// isn't feasible, but catching a fixture that no longer matches its documented shape is (#509).
// Each checker throws a descriptive error naming the file and the field, so a mismatch reads as
// a real assertion failure in fixtureShape.test.ts rather than a silent pass.

import type { Candidate } from "./ranker";

function fail(file: string, message: string): never {
  throw new Error(`${file}: ${message}`);
}

function requireObject(v: unknown, file: string, path: string): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) fail(file, `${path} must be an object`);
  return v as Record<string, unknown>;
}

function requireArray(v: unknown, file: string, path: string): unknown[] {
  if (!Array.isArray(v)) fail(file, `${path} must be an array`);
  return v;
}

function requireString(v: unknown, file: string, path: string): void {
  if (typeof v !== "string" || v.length === 0) fail(file, `${path} must be a non-empty string`);
}

function optionalString(v: unknown, file: string, path: string): void {
  if (v !== undefined && typeof v !== "string") fail(file, `${path} must be a string when present`);
}

function requireStringOrNull(v: unknown, file: string, path: string): void {
  if (v !== null && typeof v !== "string") fail(file, `${path} must be a string or null`);
}

function requireEnum(v: unknown, file: string, path: string, allowed: readonly string[]): void {
  if (typeof v !== "string" || !allowed.includes(v)) {
    fail(file, `${path} must be one of ${allowed.join(", ")}; got ${JSON.stringify(v)}`);
  }
}

function requireVersion(v: unknown, file: string, allowed: readonly number[]): number {
  if (typeof v !== "number" || !allowed.includes(v)) {
    fail(file, `version must be one of ${allowed.join(", ")}; got ${JSON.stringify(v)}`);
  }
  return v;
}

function requireNonNegativeInt(v: unknown, file: string, path: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) {
    fail(file, `${path} must be a non-negative integer`);
  }
  return v;
}

const PRODUCTION: readonly Candidate["production"][] = ["self", "agency", "unknown"];
const PROFILE: readonly Candidate["profile"][] = ["strong", "weak", "neutral"];
const COVERAGE: readonly Candidate["coverage"][] = ["likely_uncovered", "likely_covered", "unknown"];
const DISCIPLINE: readonly Candidate["discipline"][] = [
  "dance",
  "opera",
  "theater",
  "music",
  "band",
  "comedy",
  "other",
];
const REPLY_INTENT = ["interested", "wants_to_book", "has_question", "declined"] as const;
const PROVENANCE = ["act", "presenter"] as const;

// overture-uncertain.json: UncertainEvent[] (src/lib/refineContract.ts)
export function assertUncertainEventsShape(data: unknown, file: string): void {
  const items = requireArray(data, file, "(root)");
  items.forEach((item, i) => {
    const o = requireObject(item, file, `[${i}]`);
    requireString(o.title, file, `[${i}].title`);
    requireStringOrNull(o.presenter, file, `[${i}].presenter`);
    requireStringOrNull(o.venue, file, `[${i}].venue`);
    requireStringOrNull(o.performanceDate, file, `[${i}].performanceDate`);
    requireStringOrNull(o.sourceUrl, file, `[${i}].sourceUrl`);
    const guess = requireObject(o.rulesGuess, file, `[${i}].rulesGuess`);
    requireEnum(guess.production, file, `[${i}].rulesGuess.production`, PRODUCTION);
    requireEnum(guess.profile, file, `[${i}].rulesGuess.profile`, PROFILE);
    requireEnum(guess.coverage, file, `[${i}].rulesGuess.coverage`, COVERAGE);
    requireEnum(guess.discipline, file, `[${i}].rulesGuess.discipline`, DISCIPLINE);
  });
}

// overture-refined.json: EventRefinement[] (src/lib/refineClassifications.ts)
export function assertRefinedEventsShape(data: unknown, file: string): void {
  const items = requireArray(data, file, "(root)");
  items.forEach((item, i) => {
    const o = requireObject(item, file, `[${i}]`);
    requireString(o.title, file, `[${i}].title`);
    requireEnum(o.production, file, `[${i}].production`, PRODUCTION);
    requireEnum(o.profile, file, `[${i}].profile`, PROFILE);
    requireEnum(o.coverage, file, `[${i}].coverage`, COVERAGE);
    requireEnum(o.discipline, file, `[${i}].discipline`, DISCIPLINE);
    optionalString(o.fit_reason, file, `[${i}].fit_reason`);
  });
}

// overture-prep-queue.json (versions 1-2, additive: production at v2+, #586)
export function assertPrepQueueShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const items = requireArray(root.items, file, "items");
  items.forEach((item, i) => {
    const o = requireObject(item, file, `items[${i}]`);
    requireString(o.naturalKey, file, `items[${i}].naturalKey`);
    requireString(o.groupName, file, `items[${i}].groupName`);
    requireString(o.discipline, file, `items[${i}].discipline`);
    requireString(o.priorRelationship, file, `items[${i}].priorRelationship`);
    optionalString(o.venue, file, `items[${i}].venue`);
    optionalString(o.performanceDate, file, `items[${i}].performanceDate`);
    optionalString(o.websiteURL, file, `items[${i}].websiteURL`);
    optionalString(o.sourceListingURL, file, `items[${i}].sourceListingURL`);
    optionalString(o.possibleMatchName, file, `items[${i}].possibleMatchName`);
    if (o.production !== undefined) requireEnum(o.production, file, `items[${i}].production`, PRODUCTION);
  });
}

function assertPrepContact(data: unknown, file: string, path: string, provenanceRequired: boolean): void {
  const o = requireObject(data, file, path);
  optionalString(o.name, file, `${path}.name`);
  optionalString(o.role, file, `${path}.role`);
  optionalString(o.email, file, `${path}.email`);
  requireString(o.method, file, `${path}.method`);
  requireString(o.confidence, file, `${path}.confidence`);
  optionalString(o.formUrl, file, `${path}.formUrl`);
  if (provenanceRequired) {
    requireEnum(o.provenance, file, `${path}.provenance`, PROVENANCE);
  } else if (o.provenance !== undefined) {
    fail(file, `${path}.provenance must not be present before version 2`);
  }
}

// overture-prep-results.json (version 1: singular contact; version 2: contacts[], replaces it)
export function assertPrepResultsShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const results = requireArray(root.results, file, "results");
  results.forEach((item, i) => {
    const o = requireObject(item, file, `results[${i}]`);
    requireString(o.naturalKey, file, `results[${i}].naturalKey`);
    if (o.draft !== undefined) {
      const draft = requireObject(o.draft, file, `results[${i}].draft`);
      requireString(draft.subject, file, `results[${i}].draft.subject`);
      requireString(draft.body, file, `results[${i}].draft.body`);
      requireString(draft.variant, file, `results[${i}].draft.variant`);
    }
    if (version === 1) {
      if (o.contacts !== undefined) fail(file, `results[${i}].contacts must not be present before version 2`);
      if (o.contact !== undefined) assertPrepContact(o.contact, file, `results[${i}].contact`, false);
    } else {
      if (o.contact !== undefined) fail(file, `results[${i}].contact was replaced by contacts[] in version 2`);
      if (o.contacts !== undefined) {
        const contacts = requireArray(o.contacts, file, `results[${i}].contacts`);
        contacts.forEach((c, j) => assertPrepContact(c, file, `results[${i}].contacts[${j}]`, true));
      }
    }
  });
}

// overture-prep-progress.json (version 1 only): mac/scripts/prep-run.sh seeds {total, completed:0},
// the Prep workflow updates completed as it finishes each item (#354)
export function assertPrepProgressShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  const total = requireNonNegativeInt(root.total, file, "total");
  const completed = requireNonNegativeInt(root.completed, file, "completed");
  if (completed > total) fail(file, `completed (${completed}) must not exceed total (${total})`);
}

// overture-reply-classify-queue.json (versions 1-3, additive: recipientId at v2+, performanceDate at v3+)
export function assertReplyClassifyQueueShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const items = requireArray(root.items, file, "items");
  items.forEach((item, i) => {
    const o = requireObject(item, file, `items[${i}]`);
    requireString(o.naturalKey, file, `items[${i}].naturalKey`);
    requireString(o.groupName, file, `items[${i}].groupName`);
    optionalString(o.venue, file, `items[${i}].venue`);
    requireString(o.replyText, file, `items[${i}].replyText`);
    optionalString(o.recipientId, file, `items[${i}].recipientId`);
    optionalString(o.performanceDate, file, `items[${i}].performanceDate`);
  });
}

// overture-reply-classify-results.json (versions 1-3, additive: recipientId at v2+, draftSubject/draftBody at v3+)
export function assertReplyClassifyResultsShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const results = requireArray(root.results, file, "results");
  results.forEach((item, i) => {
    const o = requireObject(item, file, `results[${i}]`);
    requireString(o.naturalKey, file, `results[${i}].naturalKey`);
    requireEnum(o.intent, file, `results[${i}].intent`, REPLY_INTENT);
    optionalString(o.recipientId, file, `results[${i}].recipientId`);
    optionalString(o.draftSubject, file, `results[${i}].draftSubject`);
    optionalString(o.draftBody, file, `results[${i}].draftBody`);
  });
}

// overture-voice-feedback.json (versions 1-3, additive: outcomeRecipientId at v2+, kind at v3+)
export function assertVoiceFeedbackShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const pairs = requireArray(root.pairs, file, "pairs");
  pairs.forEach((item, i) => {
    const o = requireObject(item, file, `pairs[${i}]`);
    if (o.kind !== undefined) requireEnum(o.kind, file, `pairs[${i}].kind`, ["reply"]);
    requireString(o.naturalKey, file, `pairs[${i}].naturalKey`);
    requireString(o.discipline, file, `pairs[${i}].discipline`);
    optionalString(o.originalSubject, file, `pairs[${i}].originalSubject`);
    requireString(o.originalBody, file, `pairs[${i}].originalBody`);
    optionalString(o.sentSubject, file, `pairs[${i}].sentSubject`);
    requireString(o.sentBody, file, `pairs[${i}].sentBody`);
    requireString(o.sentAt, file, `pairs[${i}].sentAt`);
    requireString(o.outcome, file, `pairs[${i}].outcome`);
    optionalString(o.outcomeRecipientId, file, `pairs[${i}].outcomeRecipientId`);
  });
}

// Extracts the version a fixture filename encodes: "v2.json" or "queue-v2.json" -> 2; a bare
// name with no version suffix ("queue.json", "uncertain.json") -> 1, the first/only version any
// of these contracts shipped with.
export function versionFromFilename(filename: string): number {
  const match = filename.match(/v(\d+)\.json$/);
  return match ? Number(match[1]) : 1;
}
