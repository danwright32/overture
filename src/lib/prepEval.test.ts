import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  evaluatePrepResult,
  evaluateFixture,
  extractPrepResultsJson,
  type PrepEvalExpectation,
  type PrepEvalFixture,
} from "./prepEval";

// Behavioral eval for the prep-runbook's research/drafting JUDGMENT (#591). The runbook is a prompt,
// not code, so its rules (never the host venue, never a press inbox, surface both named performers,
// strict confidence) have no compiler behind them. This engine is the shared diff/assertion core that
// BOTH the always-on structural tests here AND the on-demand real-AI harness (scripts/eval-prep-runbook.sh)
// run a produced PrepResults through. These unit tests drive it with recorded/mock outputs, so no real
// (token-spending) model call happens here: they prove the engine PASSES a compliant output and, crucially,
// FLAGS each way a runbook regression could produce a bad one (the failure paths).

// #2545: the canonical GOOD draft opens with a greeting, because that is now what a correct draft looks
// like and what Overture will agree to send. `BODY_WITHOUT_A_GREETING` is the same text without it, kept
// separately so the one test that needs a headless body does not depend on this constant staying wrong.
const BODY_WITHOUT_A_GREETING =
  "My name is Dan Wright and I'm a professional arts photographer here in NYC. I'm writing in regard to " +
  "the Aurora Strings date at Carnegie Hall on March 10. I shoot unobtrusive, no-flash documentary " +
  "coverage and it would suit your program. Recent work is at danwrightphotography.com. I'd be glad to " +
  "talk about your photography plans for the night. I look forward to hearing from you.";

const CANONICAL_BODY = "Hi Emma,\n\n" + BODY_WITHOUT_A_GREETING;

function results(contacts: unknown[], extra: Record<string, unknown> = {}, draftBody = CANONICAL_BODY): unknown {
  return {
    version: 6,
    generatedAt: "2026-07-18T00:00:00.000Z",
    results: [
      {
        naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
        contacts,
        draft: {
          subject: "Photographing Aurora Strings at Carnegie Hall.",
          body: draftBody,
          // A live opener shape. This said "rate_stated" (a token from the retired offer A/B, #612) until
          // 2026-07-31, which nothing noticed because no guard had ever judged this field.
          variant: "reason-first",
        },
        ...extra,
      },
    ],
  };
}

const NAMED_ACT = {
  name: "Emma Robinson",
  role: "Marketing Director",
  email: "emma@aurorastrings.example",
  method: "named_decision_maker",
  confidence: "high",
  provenance: "act",
  sourceUrl: "https://aurorastrings.example/staff",
};

describe("evaluatePrepResult - structural validity", () => {
  it("flags output that is not a valid PrepResults shape", () => {
    const r = evaluatePrepResult({ version: 6, results: "nope" }, { description: "x" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/results must be an array|not a valid/i);
  });

  it("passes a well-formed compliant output with no extra expectations", () => {
    const r = evaluatePrepResult(results([NAMED_ACT]), { description: "baseline" });
    expect(r.pass).toBe(true);
    expect(r.failures).toEqual([]);
  });

  // #1389: the real-AI eval scores the drafter's JUDGMENT (contacts, draft, provenance), not run-level
  // metadata. A single-item eval output legitimately omits `generatedAt` (that wrapper field belongs to
  // the real Prep run writing the whole file), so it must be scored on content, never rejected on the
  // missing timestamp. Before this, every real drafting output failed structurally on generatedAt.
  it("scores a content-valid output that omits the run-level generatedAt (#1389)", () => {
    const produced = results([NAMED_ACT]) as Record<string, unknown>;
    delete produced.generatedAt;
    const r = evaluatePrepResult(produced, { description: "no generatedAt" });
    expect(r.failures.join(" ")).not.toMatch(/generatedAt/);
    expect(r.pass).toBe(true);
  });

  it("also tolerates an empty generatedAt string (#1389)", () => {
    const produced = results([NAMED_ACT]) as Record<string, unknown>;
    produced.generatedAt = "";
    const r = evaluatePrepResult(produced, { description: "empty generatedAt" });
    expect(r.failures.join(" ")).not.toMatch(/generatedAt/);
    expect(r.pass).toBe(true);
  });
});

describe("evaluatePrepResult - universal invariants (always-true runbook rules)", () => {
  it("flags a press/media/PR inbox at ANY confidence (the Carnegie Citywide trap, #635)", () => {
    const bad = results([
      { email: "publicrelations@carnegiehall.org", method: "generic_inbox", confidence: "low", provenance: "act" },
    ]);
    const r = evaluatePrepResult(bad, { description: "press must never surface" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/press|publicrelations/i);
  });

  it("flags a high-confidence contact that carries no sourceUrl (STRICT verification)", () => {
    const bad = results([
      { name: "Emma Robinson", email: "emma@aurorastrings.example", method: "named_decision_maker", confidence: "high", provenance: "act" },
    ]);
    const r = evaluatePrepResult(bad, { description: "high needs a citation" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/high.*sourceUrl|sourceUrl.*high/i);
  });

  it("flags concession language in the drafted body (#39 §3 guard)", () => {
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("it would suit", "I can offer a free session and it would suit"));
    const r = evaluatePrepResult(bad, { description: "no concession words" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/free|concession/i);
  });

  it("flags an em dash in the drafted body", () => {
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("no-flash documentary coverage", "no-flash coverage \u2014 documentary"));
    const r = evaluatePrepResult(bad, { description: "no em dash" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/dash/i);
  });

  // #2545 INVERTED this. #393 forbade a greeting in the body because the app composed one above it at
  // send; the app composes nothing now, so a body with no greeting goes out headless and Overture refuses
  // to send it (Recipient.isBlockedByGreeting). The scorer has to judge what the app judges, or a run it
  // marks perfect is a run of drafts that cannot be sent.
  it("flags a body that does NOT open with a greeting (#2545)", () => {
    const bad = results([NAMED_ACT], {}, BODY_WITHOUT_A_GREETING);
    const r = evaluatePrepResult(bad, { description: "opens with a greeting" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/greeting/i);
  });

  it("accepts a body that opens with a greeting (#2545)", () => {
    const good = results([NAMED_ACT], {}, CANONICAL_BODY);
    const r = evaluatePrepResult(good, { description: "opens with a greeting" });
    expect(r.failures.join(" ")).not.toMatch(/greeting/i);
  });

  // The shared-inbox shape: an Attn: line above the greeting must not read as "no greeting".
  it("accepts an Attn block above the greeting (#2545)", () => {
    const good = results([NAMED_ACT], {},
      "Attn: Emma Robinson, Marketing Director\n\nHello,\n\n" + BODY_WITHOUT_A_GREETING);
    const r = evaluatePrepResult(good, { description: "attn block then greeting" });
    expect(r.failures.join(" ")).not.toMatch(/greeting/i);
  });

  it("flags a link to a host other than danwrightphotography.com (#789 invented URL)", () => {
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("I look forward to hearing from you.", "My rates are at danwright-pricing.example/rates. I look forward to hearing from you."));
    const r = evaluatePrepResult(bad, { description: "only danwrightphotography.com links" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/host|link|danwrightphotography/i);
  });

  it("flags an unfilled placeholder in the body (#789)", () => {
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("Carnegie Hall", "[VENUE]"));
    const r = evaluatePrepResult(bad, { description: "no placeholder" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/placeholder/i);
  });
});

// #2265: the run reached the act's social profile and stopped, while the address sat on their own site
// one fetch away. Verified 2026-08-07 against the real case: the site published the address on a plain
// GET, no login. Scoring "did it surface SOME contact" cannot see that failure, because the run really
// did surface one, a DM. The only question that separates the two is WHICH address came back.
describe("evaluatePrepResult - the address that was actually published (#2265)", () => {
  const expected: PrepEvalExpectation = {
    description: "the act's own published address, not the social profile it is linked from",
    requiredEmails: ["ryan@example-performer.example"],
  };

  it("passes when the run reached the address published on the act's own site", () => {
    const r = evaluatePrepResult(
      results([{ name: "Ryan", email: "ryan@example-performer.example", method: "named_decision_maker", confidence: "high", provenance: "performer", sourceUrl: "https://example-performer.example/contact" }]),
      expected,
    );
    expect(r.pass).toBe(true);
  });

  // The exact shape the 2026-08-07 run produced: a contact, so every count-based check is satisfied,
  // whose only route is a profile behind a login.
  it("flags a run that stopped at the social profile", () => {
    const r = evaluatePrepResult(
      results([{ name: "Ryan", method: "form_or_dm", confidence: "low", provenance: "performer", formUrl: "https://www.instagram.example/ryan/" }]),
      expected,
    );
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/ryan@example-performer\.example/i);
  });

  it("is case and whitespace insensitive, since an address read off a page carries neither reliably", () => {
    const r = evaluatePrepResult(
      results([{ name: "Ryan", email: "  Ryan@Example-Performer.Example ", method: "named_decision_maker", confidence: "high", provenance: "performer", sourceUrl: "https://example-performer.example/contact" }]),
      expected,
    );
    expect(r.pass).toBe(true);
  });
});

describe("evaluatePrepResult - host venue disqualify (#368)", () => {
  const expected: PrepEvalExpectation = {
    description: "never the host venue",
    forbiddenEmails: ["info@metroconcerthall.example"],
    forbiddenDomains: ["metroconcerthall.example"],
  };

  it("passes when the contact is the act, not the venue", () => {
    const r = evaluatePrepResult(results([NAMED_ACT]), expected);
    expect(r.pass).toBe(true);
  });

  it("flags a contact on the forbidden venue domain", () => {
    const bad = results([
      { name: "Front Desk", email: "info@metroconcerthall.example", method: "generic_inbox", confidence: "medium", provenance: "act" },
    ]);
    const r = evaluatePrepResult(bad, expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/venue|forbidden|metroconcerthall/i);
  });
});

// #1856: on a show whose listing named no producing organisation, a `presenter` contact is a contradiction.
// Nothing was established to be the presenter, and the only organisation on the page is the room Dan is not
// pitching, so this is the shape a regression would take: the run gives up on the people and labels the
// house as the producer instead.
// #1870: an expectation matched as literal text is brittle in a way its author cannot see. A real run on
// 2026-07-31 summarised the show as "musical theatre villain songs", which is exactly what the listing says
// it is, and an expectation asking for "villains" scored that correct answer as a failure. The rule being
// checked is "did the run say what the show IS", never "did it pluralise the noun the way the fixture did",
// so the term has to be the shortest genuinely diagnostic one.
describe("evaluatePrepResult - a show summary is scored on what it says, not its word endings", () => {
  const expected: PrepEvalExpectation = {
    description: "the run said what the show is",
    requiredShowSummaryTerms: ["villain"],
  };

  it("accepts the wording a real run produced", () => {
    const produced = results([NAMED_ACT]) as { version: number; results: Array<Record<string, unknown>> };
    produced.version = 8;   // a summary is a v8 field, so the document has to declare v8 to carry one
    produced.results[0].showSummary =
      "A cabaret evening of musical theatre villain songs, sung straight, hosted by two performers.";
    const verdict = evaluatePrepResult(produced, expected);
    expect(verdict.failures).toEqual([]);
    expect(verdict.pass).toBe(true);
  });

  it("still fails a summary that never says what the show is", () => {
    const produced = results([NAMED_ACT]) as { version: number; results: Array<Record<string, unknown>> };
    produced.version = 8;
    produced.results[0].showSummary = "An evening of songs at a cabaret room, 70 minutes.";
    const verdict = evaluatePrepResult(produced, expected);
    expect(verdict.pass).toBe(false);
    expect(verdict.failures.join(" ")).toContain("villain");
  });
});

describe("evaluatePrepResult - no producing organisation was named (#1856)", () => {
  const expected: PrepEvalExpectation = {
    description: "pursue the named people, never label anyone presenter",
    requiredPerformers: ["Delaney Brown"],
    forbidPresenterProvenance: true,
  };

  const performer = {
    name: "Delaney Brown",
    email: "delaney@delaneybrown.example",
    method: "named_decision_maker",
    confidence: "high",
    provenance: "performer",
    sourceUrl: "https://delaneybrown.example/contact",
  };

  it("passes when the named host is pursued directly and nobody is called the presenter", () => {
    const verdict = evaluatePrepResult(results([performer]), expected);
    expect(verdict.failures).toEqual([]);
    expect(verdict.pass).toBe(true);
  });

  it("flags a contact labelled presenter where no producing organisation was ever named", () => {
    const verdict = evaluatePrepResult(
      results([
        performer,
        {
          name: "The Example Room",
          email: "programming@theexampleroom.example",
          method: "generic_inbox",
          confidence: "medium",
          provenance: "presenter",
        },
      ]),
      expected,
    );
    expect(verdict.pass).toBe(false);
    expect(verdict.failures.join(" ")).toContain('provenance "presenter" is not allowed');
  });

  it("still flags the run that gave up on the people entirely", () => {
    const verdict = evaluatePrepResult(results([]), expected);
    expect(verdict.pass).toBe(false);
    expect(verdict.failures.join(" ")).toContain("Delaney Brown");
  });
});

describe("evaluatePrepResult - self-produced duo surfaces BOTH performers (#366)", () => {
  const expected: PrepEvalExpectation = {
    description: "both named performers",
    requiredPerformers: ["Virgile Roche", "Anna Pierre"],
    forbidActProvenance: true,
    performerOverrideBodyRequired: true,
  };

  const performer = (name: string, coName: string) => ({
    name,
    email: `${name.split(" ")[0].toLowerCase()}@duo.example`,
    method: "named_decision_maker",
    confidence: "high",
    provenance: "performer",
    sourceUrl: "https://duo.example/bio",
    overrideBody:
      // #2545: a performer's own letter greets them by name. It goes to one person by definition, so the
      // named form is the right one here even though the shared body on a two-contact show would not be.
      `Hi ${name.split(" ")[0]},\n\n` +
      "My name is Dan Wright and I'm an arts photographer here in New York City. I'm writing about your " +
      `March 10 date at Carnegie Hall with ${coName}. I shoot unobtrusive, no-flash documentary coverage ` +
      "and it would suit your program. Recent work is at danwrightphotography.com. I'd be glad to talk about your " +
      "photography plans for the night. I look forward to hearing from you.",
  });

  it("passes when both performers appear as performer contacts with second-person overrideBody", () => {
    const r = evaluatePrepResult(
      results([performer("Virgile Roche", "Anna Pierre"), performer("Anna Pierre", "Virgile Roche")]),
      expected,
    );
    expect(r.pass).toBe(true);
  });

  it("flags when only one of the two named performers is surfaced", () => {
    const r = evaluatePrepResult(results([performer("Virgile Roche", "Anna Pierre")]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/Anna Pierre/);
  });

  it("flags provenance 'act' when the show is self-produced with named leads", () => {
    const r = evaluatePrepResult(results([NAMED_ACT]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/act/i);
  });

  it("flags a performer contact whose mailed overrideBody is written in the third person (#634)", () => {
    const thirdPerson = performer("Virgile Roche", "Anna Pierre");
    thirdPerson.overrideBody = thirdPerson.overrideBody.replace("about your March 10 date", "about Virgile Roche's March 10 date");
    const r = evaluatePrepResult(results([thirdPerson, performer("Anna Pierre", "Virgile Roche")]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/second person|overrideBody/i);
  });
});

describe("evaluatePrepResult - stale artist site misnames co-performer: flag, don't drop", () => {
  // Grounded in the runbook's own rules: partial results are fine (never drop), and a performer with no
  // corroboration against THIS performance is a misidentification risk -> mark low, not high (lines 156, 231-234).
  const expected: PrepEvalExpectation = {
    description: "uncorroborated performer kept but low confidence",
    requiredPerformers: ["Virgile Roche", "Anna Pierre"],
    lowConfidencePerformers: ["Anna Pierre"],
  };

  const keep = (name: string, confidence: string, sourceUrl?: string) => ({
    name,
    email: `${name.split(" ")[0].toLowerCase()}@duo.example`,
    method: confidence === "high" ? "named_decision_maker" : "form_or_dm",
    confidence,
    provenance: "performer",
    ...(sourceUrl ? { sourceUrl } : {}),
  });

  it("passes when the uncorroborated performer is kept at low confidence", () => {
    const r = evaluatePrepResult(
      results([keep("Virgile Roche", "high", "https://duo.example/bio"), keep("Anna Pierre", "low")]),
      expected,
    );
    expect(r.pass).toBe(true);
  });

  it("flags DROPPING the misnamed co-performer entirely", () => {
    const r = evaluatePrepResult(results([keep("Virgile Roche", "high", "https://duo.example/bio")]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/Anna Pierre/);
  });

  it("flags marking the uncorroborated performer 'high' instead of low", () => {
    const r = evaluatePrepResult(
      results([keep("Virgile Roche", "high", "https://duo.example/bio"), keep("Anna Pierre", "high", "https://stale.example/bio")]),
      expected,
    );
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/Anna Pierre.*confidence|confidence.*Anna Pierre|low/i);
  });
});

describe("evaluatePrepResult - presenter, never the venue; form outranks a venue inbox", () => {
  const expected: PrepEvalExpectation = {
    description: "act form + real presenter, no venue inbox",
    forbiddenEmails: ["boxoffice@grandtheatre.example"],
    forbiddenDomains: ["grandtheatre.example"],
    requirePresenter: true,
  };

  const actForm = {
    method: "form_or_dm",
    confidence: "low",
    provenance: "act",
    formUrl: "https://theact.example/contact",
  };
  const presenter = {
    email: "hello@presentingorg.example",
    method: "generic_inbox",
    confidence: "medium",
    provenance: "presenter",
  };

  it("passes with the act's form and a real presenter, no venue inbox", () => {
    const r = evaluatePrepResult(results([actForm, presenter]), expected);
    expect(r.pass).toBe(true);
  });

  it("flags falling back to the venue box office inbox", () => {
    const bad = results([
      { email: "boxoffice@grandtheatre.example", method: "generic_inbox", confidence: "medium", provenance: "presenter" },
    ]);
    const r = evaluatePrepResult(bad, expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/grandtheatre|venue|forbidden/i);
  });

  it("flags a missing presenter when the fixture expects one", () => {
    const r = evaluatePrepResult(results([actForm]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/presenter/i);
  });
});

describe("evaluatePrepResult - already-covered fit-risk flag (#611)", () => {
  const expected: PrepEvalExpectation = { description: "must surface the note", requireAlreadyCoveredNote: true };

  it("passes when the result carries alreadyCoveredNote", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], { alreadyCoveredNote: "Site names a Photographer in Residence." }), expected);
    expect(r.pass).toBe(true);
  });

  it("flags when the site says it has a photographer but the note is missing", () => {
    const r = evaluatePrepResult(results([NAMED_ACT]), expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/alreadyCoveredNote|covered/i);
  });
});

// #1832: one link in every draft, the site itself, and the reader clicks into whichever portfolio they
// want (Dan, 2026-07-30). Universal, so it fires with no fixture expectation set at all.
describe("evaluatePrepResult - one portfolio link, never a gallery (#1832)", () => {
  for (const gallery of ["music", "bands", "comedy", "dance", "performing-arts"]) {
    it(`flags a draft that deep-links the ${gallery} gallery`, () => {
      const bad = results([NAMED_ACT], {},
        CANONICAL_BODY.replace("danwrightphotography.com", `danwrightphotography.com/${gallery}`));
      const r = evaluatePrepResult(bad, { description: "any draft" });
      expect(r.pass).toBe(false);
      expect(r.failures.join(" ")).toMatch(/links one gallery instead of the portfolio itself/i);
    });
  }

  it("passes the portfolio link itself", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, CANONICAL_BODY), { description: "any draft" });
    expect(r.failures).toEqual([]);
  });

  // The rule is "don't pick a gallery for them", not "never link a page": a longer path that merely
  // starts with a gallery name is a different page and is left alone.
  it("does not flag a longer path that only starts with a gallery name", () => {
    const other = results([NAMED_ACT], {},
      CANONICAL_BODY.replace("danwrightphotography.com", "danwrightphotography.com-notes"));
    expect(evaluatePrepResult(other, { description: "any draft" }).failures).toEqual([]);
  });

  it("flags a draft that drops the portfolio link when the fixture requires it", () => {
    const noLink = results([NAMED_ACT], {}, CANONICAL_BODY.replace("danwrightphotography.com", "my site"));
    const r = evaluatePrepResult(noLink, { description: "cold", requirePortfolioLink: true });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/expected the portfolio link/i);
  });
});

describe("evaluatePrepResult - returning-client warm register (#1215/#1226)", () => {
  // booked = fully warm: skip the cold self-introduction AND the credential + portfolio scaffolding.
  const BOOKED_BODY =
    "Hi Emma,\n\n" +
    "It's good to see the Aurora Strings back at Carnegie Hall on March 10, and I'd be glad to cover the " +
    "night for you. Tell me where your photography plans for the night stand and I'll hold the date. I look " +
    "forward to hearing from you.";
  // warm lead = drop the cold self-introduction, keep ONE light credential and the portfolio link.
  const WARM_LEAD_BODY =
    "Hi Emma,\n\n" +
    "It was good connecting about the Aurora Strings at Carnegie Hall on March 10. I shoot unobtrusive, " +
    "no-flash documentary coverage that suits a concert program, and recent work is at " +
    "danwrightphotography.com. I'd be glad to talk about your photography plans for the night. I look " +
    "forward to hearing from you.";

  it("passes a booked draft that opens warm and drops the cold intro and portfolio scaffolding", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, BOOKED_BODY),
      { description: "booked", forbidColdSelfIntro: true, forbidGalleryLink: true });
    expect(r.failures).toEqual([]);
    expect(r.pass).toBe(true);
  });

  it("flags a booked draft that reintroduces Dan cold (CANONICAL_BODY is the cold opener)", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, CANONICAL_BODY),
      { description: "booked", forbidColdSelfIntro: true, forbidGalleryLink: true });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/cold self-introduction/i);
  });

  it("flags a booked draft that keeps the portfolio link (a returning client needs no proof)", () => {
    const withLink = BOOKED_BODY.replace("I look forward to hearing from you.",
      "Recent work is at danwrightphotography.com. I look forward to hearing from you.");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, withLink),
      { description: "booked", forbidColdSelfIntro: true, forbidGalleryLink: true });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/portfolio|gallery link/i);
  });

  it("passes a warm-lead draft that drops the intro but keeps one credential and the portfolio link", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, WARM_LEAD_BODY),
      { description: "warm", forbidColdSelfIntro: true, requirePortfolioLink: true });
    expect(r.failures).toEqual([]);
    expect(r.pass).toBe(true);
  });

  it("flags a warm-lead draft that drops the portfolio link (a warm lead has not seen his work)", () => {
    const noLink = WARM_LEAD_BODY.replace("danwrightphotography.com", "my site");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, noLink),
      { description: "warm", forbidColdSelfIntro: true, requirePortfolioLink: true });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/portfolio link/i);
  });
});

describe("extractPrepResultsJson - the real-AI harness reads the model's raw output", () => {
  const obj = { version: 6, results: [] };

  it("parses a bare JSON object", () => {
    expect(extractPrepResultsJson(JSON.stringify(obj))).toEqual(obj);
  });

  it("parses JSON inside a ```json code fence", () => {
    expect(extractPrepResultsJson("```json\n" + JSON.stringify(obj) + "\n```")).toEqual(obj);
  });

  it("parses JSON wrapped in surrounding prose", () => {
    expect(extractPrepResultsJson("Here is the result:\n" + JSON.stringify(obj) + "\nHope that helps.")).toEqual(obj);
  });

  it("throws when the output carries no JSON object at all (fail loud, never a silent pass)", () => {
    expect(() => extractPrepResultsJson("the model refused and wrote only prose")).toThrow(/no JSON object/i);
  });

  it("throws when the braces do not enclose valid JSON", () => {
    expect(() => extractPrepResultsJson("{ this is not json }")).toThrow();
  });
});

// --- The committed fixture set drives the same engine ---------------------------------------------

const fixtureDir = fileURLToPath(new URL("../../fixtures/prep-eval/", import.meta.url));

function loadFixtures(): PrepEvalFixture[] {
  return readdirSync(fixtureDir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(`${fixtureDir}${f}`, "utf8")) as PrepEvalFixture);
}

describe("prep-eval fixtures", () => {
  const fixtures = loadFixtures();

  it("has a representative fixture set covering the concrete runbook rules", () => {
    const names = fixtures.map((f) => f.name).sort();
    expect(names).toEqual([
      "agency-inbox-is-not-the-performers-contact",
      "already-covered-photographer",
      "carnegie-citywide-press-inbox",
      "five-named-performers-none-dropped",
      "host-venue-not-target",
      "listed-house-is-refused",
      "listing-credits-the-producing-company",
      "no-organiser-named-act-pursued",
      "presenter-not-venue",
      "returning-client-booked",
      "returning-client-warm-lead",
      "season-calendar-describes-no-show",
      "self-produced-duo-both-performers",
      "social-profile-is-not-the-destination",
      "solo-artist-cabaret-not-an-organisation",
      "stale-site-misnamed-co-performer",
      "venue-history-band-says-he-knows-the-room",
    ]);
  });

  // #1872: a reference answer is asserted to be COMPLIANT, so it has to satisfy the rules as they stand
  // today, not the rules of the day it was typed. These are hand-written and nothing re-reads them when a
  // runbook rule lands, so the drift runs in the direction that hides problems: a rule could be dropped
  // and every sample would keep agreeing with the version without it, because they never exercised it.
  //
  // The rule here is #1824's: an entry that drafts must say what the show IS, or say why it cannot. Read
  // off the contract's own vocabulary rather than a list repeated here, so the next value added to it is
  // covered without editing this test.
  for (const fixture of fixtures) {
    it(`${fixture.name}: its reference answer says what the show is, or why it cannot`, () => {
      const out = fixture.sampleCompliantOutput as { results?: Array<Record<string, unknown>> };
      for (const r of out.results ?? []) {
        if (!r.draft) continue;   // an entry with no draft has nothing to ground
        const said = typeof r.showSummary === "string" && r.showSummary.length > 0;
        const why = typeof r.showSummaryAbsentReason === "string" && r.showSummaryAbsentReason.length > 0;
        expect(said || why,
          `${fixture.name} drafts without saying what the show is or why it cannot`).toBe(true);
      }
    });
  }

  for (const fixture of fixtures) {
    it(`${fixture.name}: is well-formed (input, sources, expected, sampleCompliantOutput)`, () => {
      expect(typeof fixture.input).toBe("object");
      expect(Array.isArray(fixture.sources)).toBe(true);
      expect(fixture.sources.length).toBeGreaterThan(0);
      expect(typeof fixture.expected.description).toBe("string");
      expect(fixture.sampleCompliantOutput).toBeTruthy();
    });

    // #1909: scored against its OWN rule plus the durable invariants, not every wording rule. A
    // sample is a hand-written reference answer frozen at the rules of its day (#1872); scoring all
    // sixteen against every wording rule meant one copy correction invalidated the lot, at roughly 25
    // minutes and 13 real model calls to restore.
    it(`${fixture.name}: its own sampleCompliantOutput passes the eval`, () => {
      const r = evaluateFixture(fixture, fixture.sampleCompliantOutput, { scope: "durable" });
      expect(r.failures).toEqual([]);
      expect(r.pass).toBe(true);
    });
  }

  // #1723: a fixture that has only ever been shown its own compliant answer has not been seen to fail,
  // and "each guard must be seen to fail before it is trusted" is the whole point of this phase. This is
  // the regression the house fixture exists to catch: the run reads "Presented by Harbour Arts Centre",
  // takes the listing at its word, and emits the building as a presenter contact. That is precisely what
  // a run does when the house rule is dropped from the prompt, so if this output scored as a pass the
  // fixture would be decoration.
  it("listed-house-is-refused: flags a run that pitches the listed house as a presenter", () => {
    const fixture = fixtures.find((f) => f.name === "listed-house-is-refused");
    expect(fixture).toBeTruthy();
    const produced = JSON.parse(JSON.stringify(fixture!.sampleCompliantOutput)) as {
      results: Array<{ contacts: Array<Record<string, unknown>> }>;
    };
    produced.results[0].contacts.push({
      name: "Nadia Feld",
      role: "Programming Manager",
      email: "nadia@harbourarts.example",
      method: "named_decision_maker",
      confidence: "high",
      provenance: "presenter",
      sourceUrl: "https://harbourarts.example/about/staff",
    });
    const r = evaluateFixture(fixture!, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/harbourarts\.example/);
  });

  // #2382: the regression is not an invented answer either. It is exactly what the 2026-08-09 run
  // produced for this shape: the performer with nothing of her own reported at `generic_inbox` /
  // `medium` on her agency's shared address. Every count-based check passes on that output (both
  // performers are surfaced, nothing is called a presenter, no venue inbox appears), which is why the
  // fixture has to pin the agency's domain: without it the wrong answer scores clean.
  it("agency-inbox-is-not-the-performers-contact: flags a run that settles for the agency's inbox", () => {
    const fixture = fixtures.find((f) => f.name === "agency-inbox-is-not-the-performers-contact");
    expect(fixture).toBeTruthy();
    const produced = JSON.parse(JSON.stringify(fixture!.sampleCompliantOutput)) as {
      results: Array<{ contacts: Array<Record<string, unknown>> }>;
    };
    const erin = produced.results[0].contacts.find((c) => c.name === "Erin Example Grant")!;
    erin.email = "info@cresttalent.example";
    erin.method = "generic_inbox";
    erin.confidence = "medium";
    erin.sourceUrl = "https://cresttalent.example/contact/";
    delete erin.formUrl;
    const r = evaluateFixture(fixture!, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/cresttalent\.example/);
  });

  // #2259: the same discipline for the company a listing credits. The regression is not an invented
  // draft, it is exactly what the 2026-08-07 run produced: the two people named on the listing, each with
  // no address, and no company at all. Every count-based check passes on that answer, which is why the
  // fixture pins the address the company publishes.
  it("listing-credits-the-producing-company: flags a run that pursues only the people on the bill", () => {
    const fixture = fixtures.find((f) => f.name === "listing-credits-the-producing-company");
    expect(fixture).toBeTruthy();
    const produced = JSON.parse(JSON.stringify(fixture!.sampleCompliantOutput)) as {
      results: Array<{ contacts: Array<Record<string, unknown>> }>;
    };
    produced.results[0].contacts = produced.results[0].contacts.filter(
      (c) => c.provenance !== "presenter");
    const r = evaluateFixture(fixture!, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/presenter/);
    expect(r.failures.join(" ")).toMatch(/hello@fenwickproductions\.example/);
  });

  // #1824. Same discipline: each of these fixtures must be seen to FAIL on the exact draft a runbook
  // regression would produce, or it is decoration. All four are the real 2026-07-30 failure, replayed.

  function clone(fixture: PrepEvalFixture): { results: Array<Record<string, unknown>> } {
    return JSON.parse(JSON.stringify(fixture.sampleCompliantOutput));
  }

  function withBody(fixture: PrepEvalFixture, body: string): unknown {
    const produced = clone(fixture);
    (produced.results[0].draft as { body: string }).body = body;
    delete produced.results[0].contacts;   // drop the overrideBody, so only the shared body is judged
    produced.results[0].emptyReason = "nothing_published";
    return produced;
  }

  it("solo-artist-cabaret-not-an-organisation: flags a run that never says what the show is", () => {
    const fixture = fixtures.find((f) => f.name === "solo-artist-cabaret-not-an-organisation")!;
    const produced = clone(fixture);
    delete produced.results[0].showSummary;
    produced.results[0].showSummaryAbsentReason = "no_description_published";
    const r = evaluateFixture(fixture, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/showSummary does not say what the listing says|showSummary expected/i);
  });

  // The sentence Dan actually received, verbatim in shape: a category the reader does not fit.
  it("solo-artist-cabaret-not-an-organisation: flags a draft that categorizes the recipient", () => {
    const fixture = fixtures.find((f) => f.name === "solo-artist-cabaret-not-an-organisation")!;
    const r = evaluateFixture(fixture, withBody(fixture,
      "I'm a documentary photographer working with performing arts organizations in New York, and I'm "
      + "writing about photographing your August 3 show at The Example Room. Recent work is at "
      + "danwrightphotography.com. Happy to answer any questions."));
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/categorizes the recipient/i);
  });

  it("solo-artist-cabaret-not-an-organisation: flags a draft that says the show is something it is not", () => {
    const fixture = fixtures.find((f) => f.name === "solo-artist-cabaret-not-an-organisation")!;
    const r = evaluateFixture(fixture, withBody(fixture,
      "I photograph performing arts in New York and saw your opera is at The Example Room on August 3. "
      + "Recent work is at danwrightphotography.com. Happy to answer any questions."));
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/says the show is something the listing does not/i);
  });

  // #1889: the sixth rule from the 2026-07-31 review, and the only one that had no check behind it. The
  // regression is not an invented draft either: it is what two real drafts did that day, described the
  // whole offer and then asked for nothing, leaving the next step entirely with a stranger. Built by
  // DELETING the ask sentence from a recorded sample, so what is scored is a real draft minus the one
  // clause the rule is about, never a body shaped to make the rule fire.
  // Only the drafted body is touched: the contact, the note and the summary reason are the recorded ones,
  // so the produced output differs from a passing answer by the ask clause and nothing else.
  function withDraftBody(fixture: PrepEvalFixture, rewrite: (body: string) => string): unknown {
    const produced = clone(fixture);
    const draft = produced.results[0].draft as { body: string };
    const rewritten = rewrite(draft.body);
    expect(rewritten, "the rewrite must actually have matched something").not.toEqual(draft.body);
    draft.body = rewritten;
    return produced;
  }

  it("already-covered-photographer: flags a draft that states the offer and then asks for nothing", () => {
    const fixture = fixtures.find((f) => f.name === "already-covered-photographer")!;
    const produced = withDraftBody(fixture, (body) => body.replace(
      "If you don't have someone on it already, I'd be glad to talk about your photography plans for the performance. ",
      ""));
    const r = evaluateFixture(fixture, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/asks for nothing/i);
  });

  // The other half of the same rule: an ask REWRITTEN into a yes/no offer is not an ask, because it
  // invites the no. Same recorded body, with only the ask clause reworded.
  it("already-covered-photographer: flags an ask reworded into a yes/no offer", () => {
    const fixture = fixtures.find((f) => f.name === "already-covered-photographer")!;
    const produced = withDraftBody(fixture, (body) => body.replace(
      "If you don't have someone on it already, I'd be glad to talk about your photography plans for the performance.",
      "Would you like coverage of the concert?"));
    const r = evaluateFixture(fixture, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/yes\/no offer/i);
  });

  // The direction that decides whether the rule is usable at all: every draft the fixtures actually hold,
  // shared bodies and per-performer overrides alike, must still read as an ask. The accept-set is derived
  // from the recorded output rather than hand-listed here, so a phrasing that exists is covered whether or
  // not anyone remembered it (30 bodies at the time of writing, and they word the ask nine different ways).
  for (const fixture of fixtures) {
    it(`${fixture.name}: every recorded draft still reads as an ask (#1889)`, () => {
      const out = fixture.sampleCompliantOutput as {
        results?: Array<{ draft?: { body?: string }; contacts?: Array<{ overrideBody?: string }> }>;
      };
      const bodies = (out.results ?? []).flatMap((r) => [
        r.draft?.body,
        ...(r.contacts ?? []).map((c) => c.overrideBody),
      ]).filter((b): b is string => typeof b === "string" && b.length > 0);
      expect(bodies.length).toBeGreaterThan(0);
      for (const body of bodies) {
        const r = evaluatePrepResult(results([NAMED_ACT], {}, body), { description: fixture.name });
        expect(r.failures.join(" "), body).not.toMatch(/asks for nothing|yes\/no offer/i);
      }
    });
  }

  // The other direction, and the one a naive "always summarise the listing" rule gets wrong: the page is
  // a season calendar, so a summary of it is an invention about this show.
  it("season-calendar-describes-no-show: flags a summary invented from the neighbouring listings", () => {
    const fixture = fixtures.find((f) => f.name === "season-calendar-describes-no-show")!;
    const produced = clone(fixture);
    delete produced.results[0].showSummaryAbsentReason;
    produced.results[0].showSummary = "A Bach and Baroque chamber programme.";
    const r = evaluateFixture(fixture, produced);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/showSummary was invented/i);
  });
});

// Dan reviewed one real draft on 2026-07-31 and it produced five new rules. Each one below is expressed
// as a check on the produced body, so each needs a test that FAILS when the rule is broken: a universal
// check nothing exercises is indistinguishable from one that matches nothing at all.
describe("the 2026-07-31 drafting rules are enforced on the produced body", () => {
  const cold = { description: "a cold pitch" };

  it("flags a draft that names where Dan stands instead of the effect", () => {
    const body = CANONICAL_BODY.replace("I shoot unobtrusive, no-flash documentary coverage",
                                        "I shoot from the back of the house with no flash");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/where Dan stands/i);
  });

  it("flags the state when the city is meant", () => {
    const body = CANONICAL_BODY.replace("here in NYC", "here in New York");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/New York City or NYC/i);
  });

  it("does not flag New York City itself, nor a venue quoted as printed", () => {
    const body = CANONICAL_BODY.replace("here in NYC", "based in New York City")
      .replace("Recent work", "My work has taken me to Radio City Music Hall. Recent work");
    expect(evaluatePrepResult(results([NAMED_ACT], {}, body), cold).failures).toEqual([]);
  });

  it("flags a close that asks the reader to invent a question", () => {
    const body = CANONICAL_BODY.replace("I look forward to hearing from you.",
                                        "Happy to answer any questions.");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/invites the reader to ask questions/i);
  });

  it("flags a cold draft whose first sentence does not introduce Dan by name and trade", () => {
    const body = CANONICAL_BODY.replace(
      "My name is Dan Wright and I'm a professional arts photographer here in NYC.",
      "I'm writing about your March 10 date at Carnegie Hall.");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/sentence one must introduce Dan/i);
  });

  it("does not require the self-introduction of a returning client, who already knows him", () => {
    const body = "It's good to have you back at Carnegie Hall on March 10, and I'd be glad to cover it. "
      + "I'd be glad to talk about your photography plans for the night. I look forward to hearing from you.";
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body),
                                 { description: "booked", forbidColdSelfIntro: true });
    expect(r.failures.join(" ")).not.toMatch(/sentence one must introduce Dan/i);
  });

  it("flags a draft that lifts its own showSummary into the email", () => {
    const summary = "A cabaret concert of new songs by one songwriter, with a cast of five, 75 minutes.";
    const body = CANONICAL_BODY.replace(
      "I shoot unobtrusive, no-flash documentary coverage and it would suit your program.",
      "It's a concert of new songs by one songwriter, with a cast of five. I shoot unobtrusive coverage.");
    // showSummary arrived at results version 8, so the envelope has to say 8 or the shape guard rejects
    // the entry before this rule is ever reached.
    const out = results([NAMED_ACT], { showSummary: summary }, body) as Record<string, unknown>;
    out.version = 8;
    const r = evaluatePrepResult(out, cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/lifts \d+ consecutive words/i);
  });

  it("does not flag a body that merely names the show its summary describes", () => {
    const summary = "A cabaret concert of new songs by one songwriter, with a cast of five, 75 minutes.";
    const out = results([NAMED_ACT], { showSummary: summary }) as Record<string, unknown>;
    out.version = 8;
    expect(evaluatePrepResult(out, cold).failures).toEqual([]);
  });

  it("flags a cold draft that echoes a retired opener shape", () => {
    const out = results([NAMED_ACT]) as { results: Array<{ draft: { variant: string } }> };
    out.results[0].draft.variant = "observation-first";
    const r = evaluatePrepResult(out, cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/not one of the live opener shapes/i);
  });
});

// #1889: the sixth rule from Dan's 2026-07-31 review. Five of the six became checks that day because each
// was a phrase no body may CONTAIN; this one is the opposite shape, a clause every body must contain, and
// it stayed prose in docs/prep-runbook.md and the brand-voice skill for that reason alone. The runbook
// states it in three parts: the draft must actually REQUEST something; the request asks about their
// photography plans for this show, which presupposes plans exist; and rewording it into a yes/no offer
// ("would you like coverage?") throws the presupposition away and invites the no.
//
// The over-match risk runs the other way from the five negative rules: this one can fail a GOOD draft that
// words the ask unusually, which would make the check attack exactly the drafts it exists to protect. So
// the accept side is calibrated on every recorded body in fixtures/prep-eval (the loop in the fixture
// describe above) and on the rewordings below, none of which appear in the recorded set.
describe("evaluatePrepResult - the draft has to ask for something (#1889)", () => {
  const cold = { description: "a cold pitch" };

  function withAsk(ask: string): unknown {
    return results([NAMED_ACT], {},
      CANONICAL_BODY.replace("I'd be glad to talk about your photography plans for the night.", ask));
  }

  it("flags a draft that offers everything and requests nothing", () => {
    const r = evaluatePrepResult(withAsk("I'd be glad to cover it."), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/asks for nothing/i);
  });

  it("flags the ask rewritten as a yes/no offer, which invites the no", () => {
    const r = evaluatePrepResult(withAsk("Would you like coverage of the concert?"), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/yes\/no offer/i);
  });

  it("flags the door-left-open close, which is not a request either", () => {
    const r = evaluatePrepResult(withAsk("Let me know if you're interested."), cold);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/yes\/no offer|asks for nothing/i);
  });

  // Rewordings that keep the presupposition, none of them the sentence the fixtures use. The runbook asks
  // for the sentence to be reworded every draft, so a rule pinned to one spelling of it would fail on
  // instruction being followed.
  for (const ask of [
    "I'd be glad to talk through your photography plans for the evening, if you don't have someone on it already.",
    "I'd be glad to hear what you have planned for photography that night.",
    "Tell me where your photography plans for the concert stand and I'll hold the date.",
    "I'm writing to ask what your plans for photography are for the night.",
  ]) {
    it(`accepts a reworded ask: ${ask.slice(0, 40)}`, () => {
      const r = evaluatePrepResult(withAsk(ask), cold);
      expect(r.failures.join(" "), ask).not.toMatch(/asks for nothing|yes\/no offer/i);
    });
  }

  // A stored sample is a hand-written reference answer frozen at the wording rules of its day (#1909), and
  // how the ask is phrased is exactly the kind of sentence Dan retunes by reading a real draft. So this is
  // a wording rule: scored against produced output, never against a sample, or one future retune would
  // invalidate all seventeen at once.
  it("is not scored against a stored sample (#1909)", () => {
    const r = evaluatePrepResult(withAsk("I'd be glad to cover it."), cold, { scope: "durable" });
    expect(r.failures.join(" ")).not.toMatch(/asks for nothing/i);
  });
});

// #1905: the #1887 venue-history wording, which nothing had ever scored. The app hands the run a BAND
// (`shot_before` / `a_few` / `regularly`) and no number, and the runbook says three things about what
// the draft must then do: say he knows the room, alongside the credential rather than instead of it;
// never frame that familiarity as a risk avoided; and, when NO band was supplied, say nothing about
// having worked the venue at all.
//
// Both venue rules are SCOPED TO THIS SHOW'S VENUE rather than to any past-work claim, because the
// standing credential is itself written as "I've photographed at Carnegie Hall for nearly ten years".
// An unscoped check would read that as a venue-history claim and flag every compliant cold pitch.
//
// Counts are deliberately NOT re-checked here. DraftCheck.venueHistoryCount already BLOCKS a send whose
// body pairs a past-tense shooting claim with a number, and re-implementing that matcher in a second
// language is the drift L26 warns about. This covers what nothing else does: the wording.
describe("evaluatePrepResult - venue history wording (#1905)", () => {
  const KNOWS_THE_ROOM =
    "I've photographed at Harborlight Hall a few times, so I'm familiar with the room. " +
    "I've photographed at Carnegie Hall for nearly ten years, and you can see my portfolio at " +
    "danwrightphotography.com.";

  // The credential alone, naming a DIFFERENT room from the one this show plays in.
  const CREDENTIAL_ONLY =
    "I've photographed at Carnegie Hall for nearly ten years, and you can see my portfolio at " +
    "danwrightphotography.com.";

  function bodyWith(venueSentence: string): string {
    return CANONICAL_BODY.replace("Recent work is at danwrightphotography.com.", venueSentence);
  }

  it("flags a draft that was handed a venue history band and never says he knows that room", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(CREDENTIAL_ONLY)), {
      description: "a band was supplied for Harborlight Hall",
      requireVenueFamiliarity: "Harborlight Hall",
    });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/never says Dan has worked Harborlight Hall/i);
  });

  it("passes a draft that says he has worked that room", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(KNOWS_THE_ROOM)), {
      description: "a band was supplied for Harborlight Hall",
      requireVenueFamiliarity: "Harborlight Hall",
    });
    expect(r.failures).toEqual([]);
  });

  // The credential names Carnegie, not this show's room, so it must not satisfy the rule on its own.
  it("does not accept the standing credential as familiarity with a different venue", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(CREDENTIAL_ONLY)), {
      description: "a band was supplied for Harborlight Hall",
      requireVenueFamiliarity: "Harborlight Hall",
    });
    expect(r.pass).toBe(false);
  });

  // Dan flagged this shape himself: naming the bad outcome plants it in the reader's head and invites
  // them to picture a photographer fumbling in an unfamiliar room.
  it("flags familiarity framed as a risk avoided rather than as knowing the space", () => {
    const risky = "I've photographed at Harborlight Hall before, so I'm not learning the room on the night.";
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(risky)), {
      description: "a band was supplied for Harborlight Hall",
      forbidVenueRiskFraming: true,
    });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/risk avoided/i);
  });

  it("passes familiarity written as knowing the space", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(KNOWS_THE_ROOM)), {
      description: "a band was supplied for Harborlight Hall",
      forbidVenueRiskFraming: true,
    });
    expect(r.failures).toEqual([]);
  });

  // The absent case, which is the one that can invent a fact: no band means the app has no history to
  // report, so any claim of having worked THAT room came from its name, a past client, or nothing.
  it("flags a claim of having worked the venue when no band was supplied", () => {
    const invented = "I've photographed at Harborlight Hall a few times, so I know the space. " +
      "You can see my portfolio at danwrightphotography.com.";
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(invented)), {
      description: "no band was supplied for Harborlight Hall",
      forbidVenueHistoryClaim: "Harborlight Hall",
    });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/no venue history was supplied/i);
  });

  // ...but the credential naming a different room is untouched by that rule, which is the whole reason
  // it is scoped. A rule that flagged this would forbid the credential on every show.
  it("leaves the standing credential alone when no band was supplied", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, bodyWith(CREDENTIAL_ONLY)), {
      description: "no band was supplied for Harborlight Hall",
      forbidVenueHistoryClaim: "Harborlight Hall",
    });
    expect(r.failures).toEqual([]);
  });
});

// #1909: a stored sample is scored against its OWN rule plus the durable invariants, not the whole
// wording rule set.
//
// Every fixture's `sampleCompliantOutput` used to be scored against every rule, so a change to ANY
// wording rule invalidated all of them at once. Measured 2026-07-31: removing the rate from cold
// pitches (#1906) turned 29 checks red across fixtures about contact finding, house refusal and
// performer handling, none of which have anything to do with pricing. Restoring them meant a full
// real-AI run, roughly 25 minutes and 13 model calls.
//
// That cost fell on exactly the small copy corrections Dan makes after reading a real draft, which
// are the highest-value edits the runbook gets.
describe("evaluatePrepResult - sample scope (#1909)", () => {
  // A body that breaks a WORDING rule (the rate) while breaking nothing structural. This is the shape
  // of the 2026-07-31 breakage: every sample was written when stating a rate was required.
  const BODY_WITH_A_RATE = CANONICAL_BODY.replace(
    "I'd be glad to talk about your photography plans for the night.",
    "My rate is $650 plus tax. I'd be glad to talk about your photography plans for the night.");

  it("scores a wording rule against real output", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, BODY_WITH_A_RATE), { description: "x" });
    expect(r.failures.some((f) => f.includes("no rate"))).toBe(true);
  });

  it("does not score a wording rule against a stored sample", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, BODY_WITH_A_RATE), { description: "x" },
                                 { scope: "durable" });
    expect(r.failures).toEqual([]);
    expect(r.pass).toBe(true);
  });

  // The narrowing has to keep biting, or it has traded a real cost for no coverage at all. Each of
  // these is a structural fact rather than a wording choice, so none of them churns when Dan retunes
  // a sentence, and each is a genuine defect in any output whenever it appears.
  it("still flags an em dash in a stored sample", () => {
    // The dash is written as an escape, not typed. The pre-push style gate forbids the literal
    // character in source and is right to, since it cannot tell a line that USES one from a line that
    // must QUOTE one, and this test has to contain a real em dash to prove the check fires.
    const body = CANONICAL_BODY.replace("here in NYC.", "here in NYC\u2014yes.");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), { description: "x" },
                                 { scope: "durable" });
    expect(r.failures.some((f) => f.includes("em/en dash"))).toBe(true);
  });

  it("still flags an unfilled placeholder in a stored sample", () => {
    const body = CANONICAL_BODY.replace("Aurora Strings", "[ACT NAME]");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), { description: "x" },
                                 { scope: "durable" });
    expect(r.failures.some((f) => f.includes("placeholder"))).toBe(true);
  });

  it("still flags a link to somewhere other than the portfolio in a stored sample", () => {
    const body = CANONICAL_BODY.replace("danwrightphotography.com", "some-other-site.example");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, body), { description: "x" },
                                 { scope: "durable" });
    expect(r.failures.some((f) => f.includes("links a host"))).toBe(true);
  });

  // Not wording either, and both are the reason the samples are trusted as reference answers at all:
  // a press inbox is disqualified outright, and an unsourced "high" confidence is a claim with no
  // evidence behind it.
  it("still flags a press inbox in a stored sample", () => {
    const contact = { ...NAMED_ACT, email: "press@carnegiehall.example" };
    const r = evaluatePrepResult(results([contact]), { description: "x" }, { scope: "durable" });
    expect(r.failures.some((f) => f.includes("press/media/PR inbox"))).toBe(true);
  });

  it("still flags a high-confidence contact with no source in a stored sample", () => {
    const contact = { ...NAMED_ACT, sourceUrl: "" };
    const r = evaluatePrepResult(results([contact]), { description: "x" }, { scope: "durable" });
    expect(r.failures.some((f) => f.includes("sourceUrl"))).toBe(true);
  });

  // THE point of the change. Narrowing the universal rules must not narrow the fixture's own rule,
  // which is the single thing that fixture exists to prove. If this stopped being checked, every
  // sample would pass for free and the whole always-on layer would be decoration.
  it("still scores the fixture's own declared expectation", () => {
    const r = evaluatePrepResult(results([NAMED_ACT]),
                                 { description: "x", requiredPerformers: ["Someone Not In This Draft"] },
                                 { scope: "durable" });
    expect(r.pass).toBe(false);
  });

  // And every real fixture passes under the narrowed scope, which is what the always-on suite runs.
  it("every stored sample passes under its own scope", () => {
    for (const fixture of loadFixtures()) {
      const r = evaluateFixture(fixture, fixture.sampleCompliantOutput, { scope: "durable" });
      expect(r.failures, `${fixture.name}`).toEqual([]);
    }
  });
});
