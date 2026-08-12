// The shared eval engine for the prep-runbook's research/drafting JUDGMENT (#591).
//
// docs/prep-runbook.md is a PROMPT executed as a headless AI run, not compiled code, so the rules it
// encodes (never the host venue, never a press inbox, surface both named performers, strict confidence)
// have no type or compiler behind them: a runbook edit can silently break an earlier rule and nothing
// catches it until Dan sees a bad draft. This module is the deterministic core that scores a produced
// PrepResults against a fixture's expected rule outcomes. It has NO model call of its own: the always-on
// vitest suite (prepEval.test.ts) drives it with recorded/mock outputs, and the opt-in real-AI harness
// (scripts/eval-prep-runbook.sh -> scripts/eval-prep-runbook.ts) feeds it a live run's output. One
// implementation, two callers, so the pass/fail rules can never drift between them.
//
// Reuses assertPrepResultsShape from fixtureShape.ts so shape validity and rule scoring share one source.

import { assertPrepResultsShape } from "./fixtureShape";

export interface EvalSource {
  label: string;
  url?: string;
  content: string;
}

export interface PrepEvalExpectation {
  description: string;
  /** No contact may carry any of these exact addresses (a specific venue/press inbox). */
  forbiddenEmails?: string[];
  /** No contact email may match any of these (regex source strings). */
  forbiddenEmailPatterns?: string[];
  /** No contact email may sit on any of these domains (the host venue's own domain). */
  forbiddenDomains?: string[];
  /** Each name must appear as a provenance:"performer" contact (self-produced duo, #366). */
  requiredPerformers?: string[];
  /** No contact may carry provenance "act" (a self-produced show pursues performers, not the act). */
  forbidActProvenance?: boolean;
  /** At least one provenance:"presenter" contact must be present. */
  requirePresenter?: boolean;
  /**
   * #1856: no contact may carry provenance "presenter". For a show whose listing named no producing
   * organisation at all: nothing was established to be the presenter, and the only organisation on the
   * page is the room, so a presenter contact there can only be the host venue wearing another label.
   */
  forbidPresenterProvenance?: boolean;
  /** The result must carry a non-empty alreadyCoveredNote (#611). */
  requireAlreadyCoveredNote?: boolean;
  /** The result must carry at least one contact. */
  requireSomeContact?: boolean;
  /**
   * #2265: these addresses must actually come back. The only expectation that can see a run which
   * stopped one hop short: it really did surface a contact, so every count-based check passes, and the
   * contact is a social DM while the published address sat on the act's own site. What separates the
   * two answers is WHICH address came back, so that is what this asks.
   */
  requiredEmails?: string[];
  /** Every performer contact must carry a second-person overrideBody (#634). */
  performerOverrideBodyRequired?: boolean;
  /**
   * #1832: every drafted body present must carry the portfolio link. It is always the same one, so this
   * is a boolean rather than which gallery: a body that links a gallery PATH fails the universal check
   * below, whatever this says.
   */
  requirePortfolioLink?: boolean;
  /** #1215: no body may reintroduce Dan cold (booked AND warm both drop the cold self-introduction). */
  forbidColdSelfIntro?: boolean;
  /** #1215: no body may carry the portfolio/gallery link (a booked returning client needs no proof). */
  forbidGalleryLink?: boolean;
  /** These performer contacts must be PRESENT but held below "high" confidence (uncorroborated). */
  lowConfidencePerformers?: string[];
  /**
   * #1824: the result's showSummary must contain each of these (case-insensitive), i.e. the run actually
   * read the listing text it was handed and said back what the show IS.
   */
  requiredShowSummaryTerms?: string[];
  /**
   * #1824: the result must carry NO showSummary and exactly this showSummaryAbsentReason. For a page that
   * genuinely publishes no description of this show, where inventing one is the failure.
   */
  expectedShowSummaryAbsentReason?: string;
  /**
   * #1824: no drafted body may name a term the show is not, e.g. describing what the listing calls a
   * cabaret concert as an opera. Per-fixture because only the fixture knows what the show is not.
   */
  forbiddenBodyTerms?: string[];
  /**
   * #1905/#1887: the item carried a `venueHistory` band, so every drafted body must say Dan already
   * knows THIS room. The credential says the level he works at; this says he knows the space, and it is
   * the one thing in a cold pitch a stranger cannot fake. The value is the VENUE NAME, because the
   * standing credential is itself written as "I've photographed at Carnegie Hall for nearly ten years":
   * an unscoped check would read that as a venue-history claim and pass, or flag, every cold pitch.
   */
  requireVenueFamiliarity?: string;
  /**
   * #1905/#1887: the familiarity clause says he knows the space, and never names the bad outcome it
   * avoids ("so I'm not learning it on the night"). Dan flagged that shape himself: naming the bad
   * outcome plants it in the reader's head and invites them to picture a photographer fumbling in an
   * unfamiliar room, which is the opposite of what the sentence is for.
   */
  forbidVenueRiskFraming?: boolean;
  /**
   * #1905/#1887: NO band was supplied, so the app has no history to report and any claim of having
   * worked this venue was inferred from its name, a past client, or nothing at all. The exact opposite
   * of requireVenueFamiliarity, and venue-scoped for the same reason. Not usable on a Carnegie show,
   * where the omission is deliberate BECAUSE the tenure credential already names that exact room: there
   * the legitimate credential and the forbidden venue line are the same room, and no text rule can tell
   * a tenure from a history band. See fixtures/prep-eval/README.md.
   */
  forbidVenueHistoryClaim?: string;
}

export interface PrepEvalFixture {
  name: string;
  input: Record<string, unknown>;
  sources: EvalSource[];
  expected: PrepEvalExpectation;
  /**
   * The one runbook rule this fixture exists to prove, in prose. Present on every fixture on disk and
   * until #1909 not declared here at all, so nothing could read it: a field written by sixteen files
   * and consumed by none (L46). Declared now because it is what a reader needs in order to judge
   * whether a sample still demonstrates its own point.
   */
  rule: string;
  /** A hand-written PrepResults that satisfies `expected`, a reference for the real-AI harness. */
  sampleCompliantOutput: unknown;
}

export interface EvalResult {
  name: string;
  pass: boolean;
  failures: string[];
}

/**
 * Which universal rules to apply (#1909).
 *
 * `full` is real output from a model: every rule, because that is what the run is being judged on.
 *
 * `durable` is a fixture's own stored `sampleCompliantOutput`, which is a hand-written reference
 * answer rather than something a model produced. It gets the fixture's OWN declared expectation
 * (unchanged, and the single thing that fixture exists to prove) plus only the invariants that are
 * structural facts rather than wording choices.
 *
 * The distinction is the whole point. Scoring every sample against every WORDING rule meant a change
 * to any one of them invalidated all sixteen at once: removing the rate from cold pitches (#1906)
 * turned 29 checks red on 2026-07-31 across fixtures about contact finding, house refusal and
 * performer handling, none of which have anything to do with pricing, and restoring them cost a full
 * real-AI run of roughly 25 minutes and 13 model calls. That cost landed on exactly the small copy
 * corrections Dan makes after reading a real draft, which are the highest-value edits the runbook
 * gets.
 *
 * The standing caveat is unchanged: a sample still freezes at the rules of its day (#1872). This
 * narrows the set of rules that can un-freeze it; it does not make a sample self-updating.
 */
export type EvalScope = "full" | "durable";

interface Contact {
  name?: string;
  role?: string;
  email?: string;
  method?: string;
  confidence?: string;
  provenance?: string;
  formUrl?: string;
  sourceUrl?: string;
  overrideBody?: string;
}

interface ResultEntry {
  naturalKey?: string;
  contacts?: Contact[];
  draft?: { subject?: string; body?: string; variant?: string };
  alreadyCoveredNote?: string;
  showSummary?: string;
  showSummaryAbsentReason?: string;
}

// Always-true runbook rules, checked regardless of a fixture's own expectations.
const PRESS_LOCALPART = /^(press|media|publicrelations|pressoffice|press-office|mediarelations)/i;
const CONCESSION = /\b(discount|flexible|free|complimentary)\b/i;
const DASH = /[\u2014\u2013]/; // em dash / en dash, written as escapes so the source holds no literal dash
// #2545: a body must OPEN with a greeting, the inverse of #393. The app used to compose one above the
// body at send and forbade one inside it; it composes nothing now, so a body that does not greet goes out
// headless and Overture refuses to send it. The scorer has to judge what the app judges, or it marks a
// run perfect whose every draft is unsendable.
//
// An `Attn:` line for a shared inbox sits ABOVE the greeting (#610), so it is stripped before the check
// rather than counted as the opening. Kept deliberately looser than the runbook, which asks for the
// greeting on its own line: this scores whether a draft can be SENT, and the app accepts either shape.
const ATTN_BLOCK = /^\s*Attn:[^\n]*\n\s*/i;
const GREETING = /^\s*(hi|hello|hey|dear|greetings|good morning|good afternoon|good evening)\b/i;
// #1215: the ways a draft reintroduces Dan as if unknown (a cold self-introduction), which a booked or
// warm returning client must NOT get. Anchored on the naming and the "I am a photographer" credential
// self-description; a warm lead's light STYLE credential ("I shoot unobtrusive documentary coverage")
// is deliberately not one of these, since the warm register keeps it.
const COLD_SELF_INTRO = /\bmy name is\b|\bi photograph performing arts\b|\bi'?m an? (?:professional )?(?:arts |performing[- ]arts )?photographer\b|\bi am an? (?:professional )?(?:arts |performing[- ]arts )?photographer\b/i;
const PORTFOLIO_LINK = /danwrightphotography\.com/i;
// #1832: one link in every draft, the site itself, and the reader clicks into whichever portfolio they
// want (Dan, 2026-07-30). A deep link into one gallery is a choice made on their behalf. Universal, not
// per-fixture: no draft may carry one, and the app refuses to mail a body that does
// (DraftCheck.galleryPathLink), so a draft that reaches for one could not be sent anyway.
const GALLERY_PATH = /danwrightphotography\.com\/(music|bands|comedy|dance|performing-arts)(?![A-Za-z0-9-])/i;
const PLACEHOLDER = /\[[A-Z][A-Z0-9 _-]*\]/;
// #1824: describe Dan, never categorize the recipient. The 2026-07-30 draft opened "a documentary
// photographer working with performing arts organizations in New York" to ONE singer-songwriter. The
// phrase is in neither the runbook nor the skill; the model built it from Dan's identity line and applied
// it to the reader. Universal, not per-fixture: no draft may make a claim about who is reading it.
const RECIPIENT_CATEGORY =
  /\b(?:with|for|alongside)\s+(?:performing[- ]arts|arts)\s+(?:organi[sz]ations?|institutions?|companies|groups|ensembles)\b|\bcompanies like yours\b|\borgani[sz]ations like yours\b|\bgroups like yours\b/i;
// Dan, 2026-07-31. Three rules from one review, each expressible as a phrase no draft may contain, so
// each gets a check at the boundary instead of living only in the prompt (the rule-in-a-prompt-is-a-hope
// problem: docs/prep-runbook.md cannot enforce itself).
//
// Where Dan stands is his problem to solve, never a selling point: a reader who pictures a photographer
// parked at the back hears "distant" rather than "discreet". The email says the effect instead.
const VANTAGE_POINT = /\bback of (?:the )?house\b/i;
// Dan works in the CITY, a different place from the state. Deliberately anchored on a preposition rather
// than every "New York", so a venue or organisation quoted as printed ("New York, NY 10036", a group
// called the New York Something) is untouched and only Dan's own words are judged.
const STATE_NOT_CITY = /\b(?:here in|in|around|across|throughout|based in)\s+new york\b(?!\s+city)/i;
// The retired close. Inviting questions makes the reader invent one, after the email has already given
// them the rate, the turnaround and the ask.
const INVITES_QUESTIONS = /(?:happy to answer|let me know if you have|feel free to (?:reach out|ask)|if you have)\s+(?:any\s+)?questions?/i;
// #1889, the sixth rule from the same 2026-07-31 review and the only one that had no check behind it.
// The other five are each a phrase no body may CONTAIN, which is why they became checks that day; this one
// is the opposite shape, a clause every body must contain, so it stayed prose in docs/prep-runbook.md and
// in the brand-voice skill. Two real drafts that day described the whole offer, the rate and the
// turnaround, and then asked for nothing at all, leaving the next step entirely with a stranger.
//
// The runbook (§2, "CTA") specifies the ask as a request about THEIR PHOTOGRAPHY PLANS FOR THIS SHOW, and
// says why in the same breath: the plans wording presupposes that plans exist, so someone who has not
// thought about photography now assumes they should have. That presupposition is the rule, not a
// preference, and it is carried by naming their plans. Reworded into a yes/no offer ("would you like
// coverage?", "let me know if you're interested") it invites the no, which is the second check below.
//
// Calibrated on the 30 drafted bodies in fixtures/prep-eval, which word this nine different ways ("talk
// about your photography plans for the night", "talk through your photography plans for the show", "hear
// what your photography plans are for the night", "the photography plans for this one", "tell me where
// your photography plans stand"). The accept side matters more than the catch side here: a rule pinned to
// one spelling would fail a good draft for following the runbook's own instruction to reword the sentence
// every time, i.e. it would attack exactly the drafts it exists to protect.
const PHOTOGRAPHY_PLANS =
  /\b(?:photography|photo|picture)\s+plans\b|\bplan(?:s|ned|ning)\s+for\s+(?:photography|photos|pictures|coverage)\b|\bphotograph(?:y|s)\s+(?:is\s+|already\s+)?(?:sorted|arranged|planned|booked)\b/i;
// The request half. A body may name their plans without asking anything about them, so the plans clause
// has to sit in a sentence that opens a conversation about it. Every recorded phrasing does.
const ASK_CUE = /\b(?:talk|speak|discuss|hear|ask|asking|tell me|chat|learn|know)\b/i;
// The rewrite that throws the presupposition away. Each shape is one the runbook names, or its immediate
// neighbour; none appears in any recorded compliant body.
const YES_NO_OFFER =
  /\bwould you like\b|\bare you interested\b|\bif you(?:'re| are)\s+interested\b|\bif (?:photography|photos|coverage) (?:is|are) something you(?:'re| are)\b|\bdo you (?:want|need)\b|\bwhether you(?:'d| would)\s+(?:like|want)\b/i;

/**
 * #1889: does the body actually REQUEST something, and does that request presuppose they have photography
 * plans for this show? Sentence-scoped like claimsPastWorkAt above, so the plans clause and the request
 * have to occur together rather than anywhere in the email.
 */
export function asksAboutPhotographyPlans(body: string): boolean {
  for (const sentence of body.split(/[.!?\n]/)) {
    if (PHOTOGRAPHY_PLANS.test(sentence) && ASK_CUE.test(sentence)) return true;
  }
  return false;
}

// Sentence one always introduces Dan, by name AND by trade, in a COLD pitch. Checked only where the
// fixture does not set forbidColdSelfIntro, since a booked or warm reader must NOT be reintroduced
// (#1215): the two rules are exact opposites and the fixture says which register this draft is in.
const SELF_INTRO_NAME = /\b(?:my name is dan|i'?m dan\b|i am dan\b|dan wright)/i;
const SELF_INTRO_TRADE = /\bphotograph(?:er|y)\b|\bi shoot\b/i;
const DOMAIN_TOKEN = /\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?:\/[^\s)]*)?/gi;
// #1905: a claim to have WORKED this venue before. Matches the claim itself rather than the venue's
// name, so one pattern serves both the rule and its exact opposite (required when a band was supplied,
// forbidden when none was). Deliberately does NOT match the standing credential, which is written in the
// continuous "I've been photographing at ... for close to ten years" and is about the level Dan works at
// rather than about this room.
const VENUE_HISTORY_CLAIM = /\bi(?:'ve| have)\s+(?:also\s+)?(?:photographed|shot|worked|covered)\b/i;

/**
 * #1905: does the body claim past work at THIS show's venue? Split into sentences the way
 * DraftCheck.venueHistoryCount does, so the claim and the venue name have to occur together rather than
 * anywhere in the email: the credential names Carnegie in its own sentence and must not be mistaken for
 * a claim about the room this show plays in.
 */
export function claimsPastWorkAt(body: string, venue: string): boolean {
  const wanted = venue.trim().toLowerCase();
  if (!wanted) return false;
  for (const sentence of body.split(/[.!?\n]/)) {
    if (!VENUE_HISTORY_CLAIM.test(sentence)) continue;
    if (sentence.toLowerCase().includes(wanted)) return true;
  }
  return false;
}
// The framings the runbook forbids for the follow-on clause: familiarity stated as a risk avoided
// instead of as knowing the space. Taken from the shapes Dan named when he set the rule.
const VENUE_RISK_FRAMING =
  /\bnot\s+learning\b|\bno\s+guesswork\b|\bfinding\s+my\s+angles\b|\bwon'?t\s+be\s+(?:learning|finding|figuring)\b|\bwithout\s+(?:guesswork|surprises)\b/i;

/** The first sentence of a body, for the rules that govern the opener specifically. */
export function firstSentence(body: string): string {
  const trimmed = body.trim();
  const end = trimmed.search(/[.!?](?:\s|$)/);
  return end === -1 ? trimmed : trimmed.slice(0, end + 1);
}

/**
 * The longest run of words shared by two texts, lowercased and stripped of punctuation. Used to catch a
 * draft that lifts its showSummary into the email: the 2026-07-31 draft opened with its own summary
 * almost verbatim ("built around the idea that we're our own harshest critics"), which is the recital
 * "name the show, describe nothing" forbids. A word-run measure rather than an exact match, because the
 * failure reworded the summary lightly rather than pasting it.
 */
export function longestSharedWordRun(a: string, b: string): number {
  const words = (s: string) => s.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/).filter(Boolean);
  const wa = words(a);
  const wb = words(b);
  if (wa.length === 0 || wb.length === 0) return 0;
  // Classic longest-common-substring over word arrays, one row at a time.
  let best = 0;
  let prev = new Array<number>(wb.length + 1).fill(0);
  for (let i = 1; i <= wa.length; i++) {
    const cur = new Array<number>(wb.length + 1).fill(0);
    for (let j = 1; j <= wb.length; j++) {
      if (wa[i - 1] === wb[j - 1]) {
        cur[j] = prev[j - 1] + 1;
        if (cur[j] > best) best = cur[j];
      }
    }
    prev = cur;
  }
  return best;
}

/** Word-run length at which a body counts as having lifted its showSummary rather than coincidentally overlapping. */
export const LIFTED_SUMMARY_WORD_RUN = 6;

// The opener shapes a run may still report writing. Judged HERE rather than in fixtureShape.ts, whose job
// is that every past results file still decodes: those frozen fixtures carry `rate_stated` from the
// retired offer A/B (#612), so that guard cannot also police today's vocabulary. This one scores produced
// output, where echoing a retired shape means the run wrote something the runbook forbids writing.
const LIVE_OPENER_VARIANTS = new Set(["reason-first", "direct-intent"]);
const ALLOWED_LINK_HOSTS = new Set(["danwrightphotography.com", "www.danwrightphotography.com"]);

function norm(s: string | undefined): string {
  return (s ?? "").trim().toLowerCase();
}

function emailDomain(email: string): string {
  const at = email.lastIndexOf("@");
  return at >= 0 ? email.slice(at + 1).toLowerCase() : "";
}

function emailLocalpart(email: string): string {
  const at = email.lastIndexOf("@");
  return at >= 0 ? email.slice(0, at) : email;
}

function collectContacts(entries: ResultEntry[]): Contact[] {
  return entries.flatMap((e) => e.contacts ?? []);
}

function collectBodies(entries: ResultEntry[]): { label: string; body: string }[] {
  const bodies: { label: string; body: string }[] = [];
  entries.forEach((e, i) => {
    if (e.draft?.body) bodies.push({ label: `results[${i}].draft.body`, body: e.draft.body });
    (e.contacts ?? []).forEach((c, j) => {
      if (c.overrideBody) bodies.push({ label: `results[${i}].contacts[${j}].overrideBody`, body: c.overrideBody });
    });
  });
  return bodies;
}

function checkUniversal(entries: ResultEntry[], failures: string[], coldRegister: boolean,
                       scope: EvalScope = "full"): void {
  // A wording rule is one Dan retunes by reading a draft and changing his mind about how it should
  // sound. A durable one is a defect in any output whenever it appears, no matter the register or the
  // year: a stray dash, an unfilled placeholder, a link somewhere other than the portfolio, a press
  // inbox, or a "high" confidence with nothing behind it. Only the second kind is scored against a
  // stored sample.
  const wordingRules = scope === "full";
  for (const c of collectContacts(entries)) {
    if (c.email) {
      if (PRESS_LOCALPART.test(emailLocalpart(c.email))) {
        failures.push(`press/media/PR inbox is disqualified at any confidence (#635): ${c.email}`);
      }
    }
    if (norm(c.confidence) === "high" && !(c.sourceUrl && c.sourceUrl.trim().length > 0)) {
      failures.push(`STRICT verification: a "high" confidence contact must carry a sourceUrl (${c.email ?? c.name ?? "unnamed"})`);
    }
  }

  for (const { label, body } of collectBodies(entries)) {
    if (wordingRules && CONCESSION.test(body)) failures.push(`${label}: contains concession language (discount/flexible/free/complimentary)`);
    if (DASH.test(body)) failures.push(`${label}: contains an em/en dash`);
    if (wordingRules && !GREETING.test(body.replace(ATTN_BLOCK, ""))) {
      failures.push(`${label}: does not open with a greeting, so Overture will refuse to send it (#2545)`);
    }
    if (PLACEHOLDER.test(body)) failures.push(`${label}: contains an unfilled placeholder (#789)`);
    if (wordingRules && RECIPIENT_CATEGORY.test(body)) {
      failures.push(`${label}: categorizes the recipient instead of describing Dan (#1824)`);
    }
    if (GALLERY_PATH.test(body)) {
      failures.push(`${label}: links one gallery instead of the portfolio itself (#1832)`);
    }
    // #1906, reversing the rule that made the rate mandatory. Dan, 2026-07-31: "I feel like I'm
    // more likely to get a response if I don't, because they may check out my portfolio instead of
    // getting sticker shock and then email me asking about it." A cold pitch carries no price and
    // no delivery turnaround; a REPLY to someone who asked still states both, and replies are not
    // scored here.
    if (wordingRules && (/\$\s?\d/.test(body) || /\bplus tax\b/i.test(body) || /within (two|2) weeks/i.test(body))) {
      failures.push(`${label}: a cold pitch must state no rate and no turnaround`);
    }
    if (wordingRules && VANTAGE_POINT.test(body)) {
      failures.push(`${label}: names where Dan stands ("back of the house") instead of the effect`);
    }
    if (wordingRules && STATE_NOT_CITY.test(body)) {
      failures.push(`${label}: says "New York" for the city; it is New York City or NYC`);
    }
    if (wordingRules && INVITES_QUESTIONS.test(body)) {
      failures.push(`${label}: invites the reader to ask questions; the close expects a reply instead`);
    }
    // #1889. A wording rule, deliberately: how the ask is phrased is exactly the sentence Dan retunes by
    // reading a real draft, and scoring stored samples against it would put back the #1909 cost (one
    // retune invalidating every sample at once). Register-independent, unlike the self-introduction: a
    // booked or warm draft asks for the same thing a cold one does.
    if (wordingRules && !asksAboutPhotographyPlans(body)) {
      failures.push(`${label}: asks for nothing; the draft must request their photography plans for this show (#1889)`);
    }
    if (wordingRules && YES_NO_OFFER.test(body)) {
      failures.push(`${label}: collapses the ask into a yes/no offer, which invites the no; ask about their photography plans, never whether they want photography at all (#1889)`);
    }
    if (wordingRules && coldRegister) {
      const opener = firstSentence(body);
      if (!SELF_INTRO_NAME.test(opener) || !SELF_INTRO_TRADE.test(opener)) {
        failures.push(`${label}: sentence one must introduce Dan by name and by trade: "${opener}"`);
      }
    }
    for (const match of body.match(DOMAIN_TOKEN) ?? []) {
      const host = match.split("/")[0].toLowerCase().replace(/\.$/, "");
      if (!ALLOWED_LINK_HOSTS.has(host)) {
        failures.push(`${label}: links a host other than danwrightphotography.com (#789): ${host}`);
      }
    }
  }

  // Per entry, not per body: the comparison is against THIS entry's own showSummary. A draft that lifts
  // the summary is describing the show back to the person who made it, which is what the 2026-07-31
  // draft did (its opening sentence was its showSummary, lightly reworded).
  // Cold only: the archetypes govern what sentence two does once Dan has introduced himself, and a
  // booked or warm draft has no self-introduction to follow, so no archetype applies to it.
  if (wordingRules && coldRegister) {
    for (const [i, e] of entries.entries()) {
      const variant = e.draft?.variant;
      if (variant !== undefined && !LIVE_OPENER_VARIANTS.has(norm(variant))) {
        failures.push(
          `results[${i}].draft.variant is "${variant}", not one of the live opener shapes (${[...LIVE_OPENER_VARIANTS].join(", ")})`,
        );
      }
    }
  }

  for (const [i, e] of entries.entries()) {
    const summary = e.showSummary;
    if (!summary) continue;
    for (const body of [e.draft?.body, ...(e.contacts ?? []).map((c) => c.overrideBody)]) {
      if (!body) continue;
      const run = longestSharedWordRun(summary, body);
      if (run >= LIFTED_SUMMARY_WORD_RUN) {
        failures.push(
          `results[${i}]: the draft lifts ${run} consecutive words from its own showSummary; the email names the show and describes nothing`,
        );
      }
    }
  }
}

function performerContacts(contacts: Contact[]): Contact[] {
  return contacts.filter((c) => norm(c.provenance) === "performer");
}

function findByName(contacts: Contact[], name: string): Contact | undefined {
  return contacts.find((c) => norm(c.name) === norm(name));
}

function checkExpectation(entry: ResultEntry, allContacts: Contact[], exp: PrepEvalExpectation, failures: string[]): void {
  for (const c of allContacts) {
    if (!c.email) continue;
    if (exp.forbiddenEmails?.some((e) => norm(e) === norm(c.email))) {
      failures.push(`forbidden contact address surfaced: ${c.email}`);
    }
    if (exp.forbiddenDomains?.some((d) => emailDomain(c.email!) === d.toLowerCase())) {
      failures.push(`contact on a forbidden (host venue) domain: ${c.email}`);
    }
    for (const p of exp.forbiddenEmailPatterns ?? []) {
      if (new RegExp(p, "i").test(c.email)) failures.push(`contact email matches forbidden pattern /${p}/i: ${c.email}`);
    }
  }

  if (exp.forbidActProvenance && allContacts.some((c) => norm(c.provenance) === "act")) {
    failures.push(`provenance "act" is not allowed for a self-produced show with named leads (#366)`);
  }

  if (exp.forbidPresenterProvenance && allContacts.some((c) => norm(c.provenance) === "presenter")) {
    failures.push(
      `provenance "presenter" is not allowed where the listing named no producing organisation (#1856)`,
    );
  }

  for (const name of exp.requiredPerformers ?? []) {
    const c = findByName(performerContacts(allContacts), name);
    if (!c) failures.push(`required performer not surfaced (must not be dropped): ${name}`);
  }

  for (const name of exp.lowConfidencePerformers ?? []) {
    const c = findByName(performerContacts(allContacts), name);
    if (c && norm(c.confidence) === "high") {
      failures.push(`uncorroborated performer must stay below "high" confidence: ${name}`);
    }
  }

  if (exp.performerOverrideBodyRequired) {
    for (const c of performerContacts(allContacts)) {
      if (!c.overrideBody || c.overrideBody.trim().length === 0) {
        failures.push(`performer contact needs its own overrideBody (#634): ${c.name ?? "unnamed"}`);
        continue;
      }
      const second = /\byou\b|\byour\b/i.test(c.overrideBody);
      const namesSelf = c.name ? new RegExp(`\\b${c.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(c.overrideBody) : false;
      if (!second || namesSelf) {
        failures.push(`performer overrideBody must address them in the second person, not describe them in the third (#634): ${c.name ?? "unnamed"}`);
      }
    }
  }

  if (exp.requirePresenter && !allContacts.some((c) => norm(c.provenance) === "presenter")) {
    failures.push(`a presenter (real presenting org) contact was expected but none was surfaced`);
  }

  if (exp.requireAlreadyCoveredNote && !(entry.alreadyCoveredNote && entry.alreadyCoveredNote.trim().length > 0)) {
    failures.push(`alreadyCoveredNote expected (the site names its own photographer) but is missing (#611)`);
  }

  if (exp.requireSomeContact && (entry.contacts ?? []).length === 0) {
    failures.push(`at least one contact was expected but none was surfaced`);
  }

  // #2265: normalized on both sides. An address read off a page carries whatever case and padding that
  // page had, and failing a correct answer for a capital letter would make the fixture useless.
  if (exp.requiredEmails?.length) {
    const found = new Set(
      (entry.contacts ?? [])
        .map((c) => (c.email ?? "").trim().toLowerCase())
        .filter((e) => e.length > 0),
    );
    for (const wanted of exp.requiredEmails) {
      if (!found.has(wanted.trim().toLowerCase())) {
        failures.push(
          `expected the published address ${wanted}, which the act's own site carries, but it was not surfaced (#2265)`,
        );
      }
    }
  }

  if (exp.requirePortfolioLink) {
    for (const { label, body } of collectBodies([entry])) {
      if (!PORTFOLIO_LINK.test(body)) {
        failures.push(`${label}: expected the portfolio link (danwrightphotography.com) (#365)`);
      }
    }
  }

  // #1905/#1887: the three venue-history wording rules. Counts are deliberately not re-checked here:
  // DraftCheck.venueHistoryCount already BLOCKS a send whose body pairs a past-tense shooting claim with
  // a number, and a second implementation of that matcher in another language is the drift L26 warns
  // about. These cover the half nothing else judges.
  if (exp.requireVenueFamiliarity) {
    const venue = exp.requireVenueFamiliarity;
    for (const { label, body } of collectBodies([entry])) {
      if (!claimsPastWorkAt(body, venue)) {
        failures.push(`${label}: never says Dan has worked ${venue}, though the item carried a venueHistory band for it (#1887)`);
      }
    }
  }

  if (exp.forbidVenueRiskFraming) {
    for (const { label, body } of collectBodies([entry])) {
      if (VENUE_RISK_FRAMING.test(body)) {
        failures.push(`${label}: frames knowing the room as a risk avoided rather than as familiarity with the space (#1887)`);
      }
    }
  }

  if (exp.forbidVenueHistoryClaim) {
    const venue = exp.forbidVenueHistoryClaim;
    for (const { label, body } of collectBodies([entry])) {
      if (claimsPastWorkAt(body, venue)) {
        failures.push(`${label}: claims Dan has worked ${venue}, but no venue history was supplied for it, so the claim was inferred (#1887)`);
      }
    }
  }

  if (exp.forbidColdSelfIntro) {
    for (const { label, body } of collectBodies([entry])) {
      if (COLD_SELF_INTRO.test(body)) {
        failures.push(`${label}: reintroduces Dan with a cold self-introduction; a booked/warm returning client already knows his work (#1215)`);
      }
    }
  }

  // #1824: the run was handed the show's own listing text and must say back what the show IS.
  if (exp.requiredShowSummaryTerms?.length) {
    const summary = (entry.showSummary ?? "").toLowerCase();
    if (summary.trim().length === 0) {
      failures.push(`showSummary expected (the listing describes this show) but is missing (#1824)`);
    } else {
      for (const term of exp.requiredShowSummaryTerms) {
        if (!summary.includes(term.toLowerCase())) {
          failures.push(`showSummary does not say what the listing says this show is: expected "${term}" (#1824)`);
        }
      }
    }
  }

  // The other direction, and the one a naive rule gets wrong: a page that describes no show at all must
  // produce an honest absence, never an invented summary assembled from the neighbouring listings.
  if (exp.expectedShowSummaryAbsentReason) {
    if ((entry.showSummary ?? "").trim().length > 0) {
      failures.push(`showSummary was invented: this listing publishes no description of this show (#1824)`);
    }
    if (entry.showSummaryAbsentReason !== exp.expectedShowSummaryAbsentReason) {
      failures.push(`expected showSummaryAbsentReason "${exp.expectedShowSummaryAbsentReason}", got "${entry.showSummaryAbsentReason ?? "(none)"}" (#1824)`);
    }
  }

  for (const term of exp.forbiddenBodyTerms ?? []) {
    for (const { label, body } of collectBodies([entry])) {
      if (new RegExp(`\\b${term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(body)) {
        failures.push(`${label}: says the show is something the listing does not: "${term}" (#1824)`);
      }
    }
  }

  if (exp.forbidGalleryLink) {
    for (const { label, body } of collectBodies([entry])) {
      if (PORTFOLIO_LINK.test(body)) {
        failures.push(`${label}: carries the portfolio/gallery link; a booked returning client needs no credential scaffolding (#1215)`);
      }
    }
  }
}

/**
 * Score a produced PrepResults object against a single expectation. Structural validity is checked first
 * (via the shared shape asserter); a shape failure short-circuits with that message. Contact- and
 * body-level scans cover every result; entry-level checks use the first result (the eval fixtures are
 * single-item work-lists).
 */
export function evaluatePrepResult(produced: unknown, expected: PrepEvalExpectation,
                                   ctx?: { name?: string; scope?: EvalScope }): EvalResult {
  const name = ctx?.name ?? expected.description;
  const failures: string[] = [];

  // #1389: the eval scores the drafter's JUDGMENT (contacts, draft, provenance), not run-level metadata.
  // A single-item eval output legitimately omits `generatedAt` (that wrapper field belongs to the real
  // Prep run that writes the whole file, not to drafting one item), so inject a placeholder when it is
  // missing or empty rather than rejecting an otherwise-valid result on a timestamp the eval never judges.
  let normalized = produced;
  if (produced && typeof produced === "object" && !Array.isArray(produced)) {
    const obj = produced as Record<string, unknown>;
    const hasGeneratedAt = typeof obj.generatedAt === "string" && obj.generatedAt.length > 0;
    if (!hasGeneratedAt) normalized = { ...obj, generatedAt: "eval" };
  }

  const version = (normalized as { version?: unknown })?.version;
  try {
    assertPrepResultsShape(normalized, "(produced output)", typeof version === "number" ? version : 6);
  } catch (e) {
    return { name, pass: false, failures: [`output is not a valid PrepResults: ${(e as Error).message}`] };
  }

  const entries = ((normalized as { results?: ResultEntry[] }).results ?? []) as ResultEntry[];
  if (entries.length === 0) {
    failures.push(`output has no results entry`);
    return { name, pass: false, failures };
  }

  const allContacts = collectContacts(entries);
  // forbidColdSelfIntro marks a booked/warm fixture (#1215), the one register where reintroducing Dan is
  // the failure. Everything else is a cold pitch, where the self-introduction is REQUIRED, so the flag
  // decides which of the two opposite rules applies rather than each fixture opting in.
  checkUniversal(entries, failures, !expected.forbidColdSelfIntro, ctx?.scope ?? "full");
  // #1909: NEVER narrowed by scope. This is the fixture's own declared rule, the single thing it
  // exists to prove, so a stored sample that stopped being scored against it would pass for free and
  // the whole always-on layer would become decoration.
  checkExpectation(entries[0], allContacts, expected, failures);

  return { name, pass: failures.length === 0, failures };
}

/** Score a produced output against a fixture's own expectation, tagging the result with the fixture name. */
export function evaluateFixture(fixture: PrepEvalFixture, produced: unknown,
                                opts?: { scope?: EvalScope }): EvalResult {
  return evaluatePrepResult(produced, fixture.expected, { name: fixture.name, scope: opts?.scope });
}

/**
 * Pull the PrepResults JSON object out of raw model output: strip code fences, then take the first '{'
 * through the matching last '}'. Throws (never returns junk) when nothing parseable is present, so an
 * unreadable output is the run having failed loudly, never a silent pass. Lives here, not in the CLI, so
 * the real-AI harness and its tests share one implementation.
 */
export function extractPrepResultsJson(raw: string): unknown {
  const unfenced = raw.replace(/```[a-zA-Z]*\n?/g, "").replace(/```/g, "");
  const start = unfenced.indexOf("{");
  const end = unfenced.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error("no JSON object found in the produced output");
  }
  return JSON.parse(unfenced.slice(start, end + 1));
}
