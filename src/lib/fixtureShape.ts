// Lightweight structural checks for the JSON handoff contracts where one side is a Claude
// Code workflow, not code (docs/contracts.md's "CI coverage" section): prep-queue,
// prep-results, reply-classify, voice-feedback. Full behavioral testing of the workflow side
// isn't feasible, but catching a fixture that no longer matches its documented shape is (#509).
// Each checker throws a descriptive error naming the file and the field, so a mismatch reads as
// a real assertion failure in fixtureShape.test.ts rather than a silent pass.

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

const PRODUCTION = ["self", "agency", "unknown"] as const;
const REPREP_MODE = ["draft_only", "contacts_only"] as const;
// #1887: the three bands, and never a count. The vocabulary is closed because an unrecognised token
// would leave the drafter to decide what it means, which is exactly what the band exists to prevent.
const VENUE_HISTORY_BAND = ["shot_before", "a_few", "regularly"] as const;
// #5 v5: the four opener archetypes an A/B experiment item can be told to use.
// Two lists, because the two directions have opposite obligations after the 2026-07-31 retirement of
// credential-first and observation-first.
//
// INBOUND (the queue's experimentArmInstruction) must still accept a retired token. It is copied from a
// Prospect.assignedArm that may have been stamped before the retirement, and v5.json/v6.json are frozen
// contract fixtures carrying exactly that. Refusing it here would fail to decode real history, so the
// runbook handles it instead: write the closest live shape and record THAT.
const OPENER_ARCHETYPE_ASSIGNABLE = [
  "reason-first", "credential-first", "observation-first", "direct-intent",
] as const;
// OUTBOUND (the drafter's echoed `variant`) accepts only the live shapes. An echo naming a retired one
// is a run reporting that it wrote a shape the runbook forbids writing, which is a drift signal, not
// history, so this is the boundary that catches it.
const OPENER_ARCHETYPE = ["reason-first", "direct-intent"] as const;
const REPLY_INTENT = ["interested", "wants_to_book", "has_question", "declined"] as const;
const PROVENANCE = ["act", "performer", "presenter"] as const;

// overture-prep-queue.json (versions 1-12, additive: production at v2+ #586, reprepMode at v3+ #367,
// runEndDate + openingNightPassed at v4+ #1122, experimentArmInstruction at v5+ #5,
// alsoAnswersFor at v6+ #1597, run-level houses at v7+ #1720, showListing at v8+ #1824,
// onlyTheActIsNamed at v9+ #1856, venueHistory at v10+ #1887,
// organisationNamedOnListing at v11+ #2259, refusedEmails at v12+ #2392)
export function assertPrepQueueShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  // #1720 v7: the RUN-LEVEL house list, the organisations the app has judged to be the building rather
  // than the act. Beside items, not inside them, because it is one answer about the whole store.
  if (version >= 7) {
    if (root.houses !== undefined) {
      const houses = requireArray(root.houses, file, "houses");
      houses.forEach((h, i) => {
        const o = requireObject(h, file, `houses[${i}]`);
        requireString(o.key, file, `houses[${i}].key`);
        requireString(o.name, file, `houses[${i}].name`);
        // The key is what an exact lookup compares against, so it must already be ProducerGate.key's
        // folded form. A key carrying capitals or a leading "the" was folded by something else and
        // would simply never match, which is indistinguishable from an empty list: the run would go on
        // deciding for itself, with the guard green the whole time.
        const key = o.key as string;
        if (key !== key.toLowerCase() || key.startsWith("the ") || key.trim() !== key) {
          fail(file, `houses[${i}].key must be a folded key (lowercased, no leading "the", trimmed)`);
        }
      });
    }
  } else if (root.houses !== undefined) {
    fail(file, `houses must not be present before version 7`);
  }
  const items = requireArray(root.items, file, "items");
  // v4 (#1122): the run's closing night and a passed-opening flag, so the drafter can pitch the whole
  // run and never name a gone opening night.
  const runFieldsAllowed = version >= 4;
  // #5 v5: the opener archetype an A/B experiment item must use (one of OPENER_ARCHETYPE), forbidden on
  // older versions so an accidental stamp on a v1-v4 queue is caught rather than silently ignored.
  const experimentFieldAllowed = version >= 5;
  // #1597 v6: the other shows one research pass answers for. Forbidden on older versions so a stamp on a
  // v1-v5 queue is caught rather than silently ignored by a runner that predates the rule and would then
  // leave every covered show unanswered.
  const groupFieldAllowed = version >= 6;
  // #1856 v9: whether this show names any producing organisation at all. Forbidden on older versions for
  // the same reason as every field above: a stamp a runner predating the rule would silently ignore is
  // worse than an error, because the run would go on hunting an organisation that does not exist and
  // report that nobody publishes an address.
  const actNamingFieldAllowed = version >= 9;
  // #1887 v10: how well Dan already knows this room, as a BAND and never a count. Forbidden on older
  // versions for the same reason as every field above, and with a closed vocabulary: an unrecognised
  // token would leave the drafter to invent what it means, which is the one thing the band exists to
  // prevent.
  const venueHistoryFieldAllowed = version >= 10;
  // #2259 v11: the producing company this show's own listing page credits in front of its title. Forbidden
  // on older versions for the same reason as every field above: a runner predating the rule would ignore
  // it and go on being told, by onlyTheActIsNamed alone, that the page named nobody.
  const listingOrganisationFieldAllowed = version >= 11;
  // #2392 v12: the addresses Dan struck on this show. Forbidden on older versions for the same reason as
  // every field above: a runner predating the rule would ignore it and go on spending on an address he
  // had already refused.
  const refusedEmailsFieldAllowed = version >= 12;
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
    if (o.reprepMode !== undefined) requireEnum(o.reprepMode, file, `items[${i}].reprepMode`, REPREP_MODE);
    if (runFieldsAllowed) {
      optionalString(o.runEndDate, file, `items[${i}].runEndDate`);
      if (o.openingNightPassed !== undefined && typeof o.openingNightPassed !== "boolean") {
        fail(file, `items[${i}].openingNightPassed must be a boolean`);
      }
    } else {
      if (o.runEndDate !== undefined) fail(file, `items[${i}].runEndDate must not be present before version 4`);
      if (o.openingNightPassed !== undefined) {
        fail(file, `items[${i}].openingNightPassed must not be present before version 4`);
      }
    }
    if (experimentFieldAllowed) {
      if (o.experimentArmInstruction !== undefined) {
        requireEnum(o.experimentArmInstruction, file, `items[${i}].experimentArmInstruction`,
                    OPENER_ARCHETYPE_ASSIGNABLE);
      }
    } else if (o.experimentArmInstruction !== undefined) {
      fail(file, `items[${i}].experimentArmInstruction must not be present before version 5`);
    }
    if (groupFieldAllowed) {
      if (o.alsoAnswersFor !== undefined) {
        const keys = requireArray(o.alsoAnswersFor, file, `items[${i}].alsoAnswersFor`);
        keys.forEach((k, j) => requireString(k, file, `items[${i}].alsoAnswersFor[${j}]`));
        if (keys.includes(o.naturalKey)) {
          fail(file, `items[${i}].alsoAnswersFor must not repeat the item's own naturalKey`);
        }
      }
    } else if (o.alsoAnswersFor !== undefined) {
      fail(file, `items[${i}].alsoAnswersFor must not be present before version 6`);
    }
    if (actNamingFieldAllowed) {
      if (o.onlyTheActIsNamed !== undefined && typeof o.onlyTheActIsNamed !== "boolean") {
        fail(file, `items[${i}].onlyTheActIsNamed must be a boolean`);
      }
    } else if (o.onlyTheActIsNamed !== undefined) {
      fail(file, `items[${i}].onlyTheActIsNamed must not be present before version 9`);
    }
    if (venueHistoryFieldAllowed) {
      if (o.venueHistory !== undefined) {
        requireEnum(o.venueHistory, file, `items[${i}].venueHistory`, VENUE_HISTORY_BAND);
      }
    } else if (o.venueHistory !== undefined) {
      fail(file, `items[${i}].venueHistory must not be present before version 10`);
    }
    if (listingOrganisationFieldAllowed) {
      optionalString(o.organisationNamedOnListing, file, `items[${i}].organisationNamedOnListing`);
      // An empty string would read as "the app looked and found a company", which is the opposite of what
      // it means. Absent is the only way to say nothing here.
      if (typeof o.organisationNamedOnListing === "string" && o.organisationNamedOnListing.trim() === "") {
        fail(file, `items[${i}].organisationNamedOnListing must be absent rather than empty`);
      }
      // A company credited on a page the app never read cannot have been read off it.
      if (o.organisationNamedOnListing !== undefined && o.showListing === undefined) {
        fail(file, `items[${i}].organisationNamedOnListing requires a showListing to have been read from`);
      }
    } else if (o.organisationNamedOnListing !== undefined) {
      fail(file, `items[${i}].organisationNamedOnListing must not be present before version 11`);
    }
    if (refusedEmailsFieldAllowed) {
      if (o.refusedEmails !== undefined) {
        if (!Array.isArray(o.refusedEmails)) fail(file, `items[${i}].refusedEmails must be an array`);
        // An empty array would tell the run to reason about a list that says nothing. Absent is the only
        // way to say "he has struck nothing here", and the writer only ever emits the field when it has
        // something in it.
        if ((o.refusedEmails as unknown[]).length === 0) {
          fail(file, `items[${i}].refusedEmails must be absent rather than empty`);
        }
        (o.refusedEmails as unknown[]).forEach((e, j) => {
          requireString(e, file, `items[${i}].refusedEmails[${j}]`);
          // A blank entry is an address the run cannot compare anything against, so it would silently
          // protect nobody while looking like a refusal.
          if (typeof e === "string" && e.trim() === "") {
            fail(file, `items[${i}].refusedEmails[${j}] must not be blank`);
          }
        });
      }
    } else if (o.refusedEmails !== undefined) {
      fail(file, `items[${i}].refusedEmails must not be present before version 12`);
    }
  });
}

function assertPrepContact(
  data: unknown,
  file: string,
  path: string,
  provenanceRequired: boolean,
  overrideBodyAllowed: boolean,
  sourceUrlAllowed: boolean,
  nameMatchOnlyAllowed: boolean,
): void {
  const o = requireObject(data, file, path);
  optionalString(o.name, file, `${path}.name`);
  optionalString(o.role, file, `${path}.role`);
  optionalString(o.email, file, `${path}.email`);
  requireString(o.method, file, `${path}.method`);
  requireString(o.confidence, file, `${path}.confidence`);
  optionalString(o.formUrl, file, `${path}.formUrl`);
  if (sourceUrlAllowed) {
    optionalString(o.sourceUrl, file, `${path}.sourceUrl`);
  } else if (o.sourceUrl !== undefined) {
    fail(file, `${path}.sourceUrl must not be present before version 6`);
  }
  if (provenanceRequired) {
    requireEnum(o.provenance, file, `${path}.provenance`, PROVENANCE);
  } else if (o.provenance !== undefined) {
    fail(file, `${path}.provenance must not be present before version 2`);
  }
  if (overrideBodyAllowed) {
    optionalString(o.overrideBody, file, `${path}.overrideBody`);
  } else if (o.overrideBody !== undefined) {
    fail(file, `${path}.overrideBody must not be present before version 4`);
  }
  // #2912: the run's declaration that only the NAME matched. A BOOLEAN, and true is the only value
  // worth writing: the app reads absence as "nobody has said", so a `false` says nothing a missing
  // field did not. It is refused as a string ("true" is what a model reaching for this field writes
  // first, and it would read as absent all the way to Dan's card).
  if (nameMatchOnlyAllowed) {
    if (o.nameMatchOnly !== undefined && typeof o.nameMatchOnly !== "boolean") {
      fail(file, `${path}.nameMatchOnly must be a boolean when present`);
    }
    // A name match is by definition not verified, and `high` is reserved for an address read off a page
    // naming the target. The pair contradicts itself, and the app resolves it by storing `low`; refusing
    // it here means the contradiction is never written in the first place.
    if (o.nameMatchOnly === true && o.confidence === "high") {
      fail(file, `${path}.nameMatchOnly cannot be high confidence`);
    }
  } else if (o.nameMatchOnly !== undefined) {
    fail(file, `${path}.nameMatchOnly must not be present before version 10`);
  }
}

// overture-prep-results.json (version 1: singular contact; version 2: contacts[], replaces it;
// version 3: adds "performer" to the provenance vocabulary, #587; version 5: adds an optional
// alreadyCoveredNote fit-risk flag on the result itself, #611; version 6: adds an optional
// sourceUrl per contact, #363; version 7: adds an optional emptyReason on the result itself, REQUIRED
// when contacts is absent, #1722; version 8: adds an optional showSummary plus a showSummaryAbsentReason
// that is REQUIRED when there is no summary, #1824; version 10: adds an optional boolean
// nameMatchOnly per contact, #2912)
export function assertPrepResultsShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const results = requireArray(root.results, file, "results");
  const overrideBodyAllowed = version >= 4;
  const emptyReasonAllowed = version >= 7;
  const showSummaryAllowed = version >= 8;
  const alreadyCoveredNoteAllowed = version >= 5;
  const sourceUrlAllowed = version >= 6;
  const nameMatchOnlyAllowed = version >= 10;
  results.forEach((item, i) => {
    const o = requireObject(item, file, `results[${i}]`);
    requireString(o.naturalKey, file, `results[${i}].naturalKey`);
    if (o.draft !== undefined) {
      const draft = requireObject(o.draft, file, `results[${i}].draft`);
      requireString(draft.subject, file, `results[${i}].draft.subject`);
      requireString(draft.body, file, `results[${i}].draft.body`);
      // Deliberately a string, not an enum. The frozen fixtures v1 to v8 carry `rate_stated`, a token
      // from the RETIRED offer A/B (#612), so this file's job (an old results file still decodes) is at
      // odds with judging whether a shape is one the runbook currently permits. That judgement belongs to
      // prepEval, which scores PRODUCED output rather than guaranteeing history parses.
      requireString(draft.variant, file, `results[${i}].draft.variant`);
    }
    if (alreadyCoveredNoteAllowed) {
      optionalString(o.alreadyCoveredNote, file, `results[${i}].alreadyCoveredNote`);
    } else if (o.alreadyCoveredNote !== undefined) {
      fail(file, `results[${i}].alreadyCoveredNote must not be present before version 5`);
    }
    // #1722: the reason an entry carries no contacts. The runbook disqualifies a venue or press address
    // rather than emitting it, so this is the only trace a refusal leaves, and an entry with neither
    // contacts nor a reason is the shape that made the card claim the search found nothing (L11).
    if (emptyReasonAllowed) {
      // #1817 adds "no_one_identified": the check could not work out who to write to, which is a different
      // finding from the people being found and publishing nothing. Widening the values is additive with no
      // version bump, because an app that does not know a value drops it and falls back to the plain
      // wording, which is exactly what the runbook already tells the run to expect.
      const EMPTY_REASONS = ["only_venue_contact", "only_press_contact", "nothing_published",
                             "no_one_identified"];
      optionalString(o.emptyReason, file, `results[${i}].emptyReason`);
      if (o.emptyReason !== undefined && !EMPTY_REASONS.includes(o.emptyReason as string)) {
        fail(file, `results[${i}].emptyReason must be one of ${EMPTY_REASONS.join(", ")}; got ${String(o.emptyReason)}`);
      }
      const hasContacts = Array.isArray(o.contacts) && o.contacts.length > 0;
      if (!hasContacts && o.contact === undefined && o.emptyReason === undefined) {
        fail(file, `results[${i}] has no contacts, so it must carry an emptyReason saying why`);
      }
    } else if (o.emptyReason !== undefined) {
      fail(file, `results[${i}].emptyReason must not be present before version 7`);
    }
    // #1824: what the run understood the show to BE, read off the listing text the app rendered and handed
    // over. An entry with no summary must say WHY, or "we could not tell" and "nobody asked" become the
    // same silence, and the whole point of writing it back is that the rule leaves a checkable trace (L27).
    if (showSummaryAllowed) {
      const ABSENT_REASONS = ["no_listing_page", "page_unreadable", "no_description_published"];
      optionalString(o.showSummary, file, `results[${i}].showSummary`);
      optionalString(o.showSummaryAbsentReason, file, `results[${i}].showSummaryAbsentReason`);
      if (o.showSummaryAbsentReason !== undefined && !ABSENT_REASONS.includes(o.showSummaryAbsentReason as string)) {
        fail(file, `results[${i}].showSummaryAbsentReason must be one of ${ABSENT_REASONS.join(", ")}; got ${String(o.showSummaryAbsentReason)}`);
      }
      const hasSummary = typeof o.showSummary === "string" && (o.showSummary as string).trim().length > 0;
      if (!hasSummary && o.showSummaryAbsentReason === undefined) {
        fail(file, `results[${i}] has no showSummary, so it must carry a showSummaryAbsentReason saying why`);
      }
    } else if (o.showSummary !== undefined || o.showSummaryAbsentReason !== undefined) {
      fail(file, `results[${i}].showSummary/showSummaryAbsentReason must not be present before version 8`);
    }
    if (version === 1) {
      if (o.contacts !== undefined) fail(file, `results[${i}].contacts must not be present before version 2`);
      if (o.contact !== undefined) assertPrepContact(o.contact, file, `results[${i}].contact`, false, overrideBodyAllowed, sourceUrlAllowed, nameMatchOnlyAllowed);
    } else {
      if (o.contact !== undefined) fail(file, `results[${i}].contact was replaced by contacts[] in version 2`);
      if (o.contacts !== undefined) {
        const contacts = requireArray(o.contacts, file, `results[${i}].contacts`);
        contacts.forEach((c, j) => assertPrepContact(c, file, `results[${i}].contacts[${j}]`, true, overrideBodyAllowed,
                                        sourceUrlAllowed, nameMatchOnlyAllowed));
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
  // #2873: OPTIONAL, matching ReplyClassifyResults on the Swift side, because the live runner does not
  // write it. This side required it too, so both definitions of the contract agreed with each other and
  // neither agreed with the writer, which is how the app went months unable to decode a single real
  // results file while every fixture and both guards stayed green.
  optionalString(root.generatedAt, file, "generatedAt");
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

// Extracts the version a fixture filename encodes: "v2.json" or "queue-v2.json" -> 2.
//
// #2340: a name carrying no version is REFUSED, not read as version 1. It used to default, so a
// fixture named without one was silently validated against the OLDEST version's rules rather than
// reported as unclassifiable, and a file whose contents happened to satisfy version 1 would have
// passed while being checked against rules that did not apply to it. That is the same class as a
// guard measuring nothing (#2311). It was hit for real on 2026-08-08: #1678's two run-metadata
// fixtures, named without a version, were checked as version 1, and only their own `version` field
// disagreeing loudly gave it away.
//
// Every fixture therefore carries its version in its name, including the v1 ones (the two
// reply-classify files were renamed for this).
export function versionFromFilename(filename: string): number {
  const match = filename.match(/v(\d+)\.json$/);
  if (!match) {
    throw new Error(
      `${filename}: fixture filename carries no version (expected a "-vN.json" suffix), ` +
      "so there is no way to know which version's rules to check it against");
  }
  return Number(match[1]);
}
