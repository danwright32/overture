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

const CANONICAL_BODY =
  "I photograph performing arts in New York and saw Aurora Strings is performing at Carnegie Hall on " +
  "March 10. I shoot unobtrusive, no-flash documentary coverage and it would suit your program. My rate " +
  "is $250 an hour plus tax, one-hour minimum, with the gallery delivered within two weeks. Recent work " +
  "is at danwrightphotography.com/music. Let me know how that lands.";

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
          variant: "rate_stated",
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

  it("flags a greeting token at the start of the body (#393)", () => {
    const bad = results([NAMED_ACT], {}, "Hi Emma, " + CANONICAL_BODY);
    const r = evaluatePrepResult(bad, { description: "no greeting token" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/greeting/i);
  });

  it("flags a link to a host other than danwrightphotography.com (#789 invented URL)", () => {
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("Let me know how that lands.", "My rates are at danwright-pricing.example/rates. Let me know how that lands."));
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
      `I photograph performing arts in New York and saw you and ${coName} are performing at Carnegie Hall on ` +
      "March 10. I shoot unobtrusive, no-flash documentary coverage and it would suit your program. My rate " +
      "is $250 an hour plus tax, one-hour minimum, with the gallery in two weeks. Recent work is at " +
      "danwrightphotography.com/music. Let me know how that lands.",
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
    thirdPerson.overrideBody = thirdPerson.overrideBody.replace("saw you and Anna Pierre are", "saw Virgile Roche and Anna Pierre are");
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

describe("evaluatePrepResult - discipline gallery link (#365)", () => {
  it("flags a draft that links the wrong discipline gallery", () => {
    const expected: PrepEvalExpectation = { description: "music gallery", expectedGalleryLink: "danwrightphotography.com/music" };
    const bad = results([NAMED_ACT], {}, CANONICAL_BODY.replace("danwrightphotography.com/music", "danwrightphotography.com/dance"));
    const r = evaluatePrepResult(bad, expected);
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/gallery|music/i);
  });
});

describe("evaluatePrepResult - returning-client warm register (#1215/#1226)", () => {
  // booked = fully warm: skip the cold self-introduction AND the credential + portfolio scaffolding.
  const BOOKED_BODY =
    "It's good to see the Aurora Strings back at Carnegie Hall on March 10. I'd love to photograph the " +
    "night for you. My rate is $250 an hour plus tax, one-hour minimum, with the gallery delivered within " +
    "two weeks. Happy to answer any questions.";
  // warm lead = drop the cold self-introduction, keep ONE light credential and the portfolio link.
  const WARM_LEAD_BODY =
    "It was good connecting about the Aurora Strings at Carnegie Hall on March 10, and I'd love to " +
    "photograph it. I shoot unobtrusive, no-flash documentary coverage that suits a concert program, and " +
    "recent work is at danwrightphotography.com/music. My rate is $250 an hour plus tax, one-hour minimum, " +
    "with the gallery delivered within two weeks. Happy to answer any questions.";

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
    const withLink = BOOKED_BODY.replace("Happy to answer any questions.",
      "Recent work is at danwrightphotography.com/music. Happy to answer any questions.");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, withLink),
      { description: "booked", forbidColdSelfIntro: true, forbidGalleryLink: true });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/portfolio|gallery link/i);
  });

  it("passes a warm-lead draft that drops the intro but keeps one credential and the portfolio link", () => {
    const r = evaluatePrepResult(results([NAMED_ACT], {}, WARM_LEAD_BODY),
      { description: "warm", forbidColdSelfIntro: true, expectedGalleryLink: "danwrightphotography.com/music" });
    expect(r.failures).toEqual([]);
    expect(r.pass).toBe(true);
  });

  it("flags a warm-lead draft that drops the portfolio link (a warm lead has not seen his work)", () => {
    const noLink = WARM_LEAD_BODY.replace("danwrightphotography.com/music", "my site");
    const r = evaluatePrepResult(results([NAMED_ACT], {}, noLink),
      { description: "warm", forbidColdSelfIntro: true, expectedGalleryLink: "danwrightphotography.com/music" });
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/gallery link/i);
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
      "already-covered-photographer",
      "carnegie-citywide-press-inbox",
      "host-venue-not-target",
      "listed-house-is-refused",
      "presenter-not-venue",
      "returning-client-booked",
      "returning-client-warm-lead",
      "season-calendar-describes-no-show",
      "self-produced-duo-both-performers",
      "solo-artist-cabaret-not-an-organisation",
      "stale-site-misnamed-co-performer",
    ]);
  });

  for (const fixture of fixtures) {
    it(`${fixture.name}: is well-formed (input, sources, expected, sampleCompliantOutput)`, () => {
      expect(typeof fixture.input).toBe("object");
      expect(Array.isArray(fixture.sources)).toBe(true);
      expect(fixture.sources.length).toBeGreaterThan(0);
      expect(typeof fixture.expected.description).toBe("string");
      expect(fixture.sampleCompliantOutput).toBeTruthy();
    });

    it(`${fixture.name}: its own sampleCompliantOutput passes the eval`, () => {
      const r = evaluateFixture(fixture, fixture.sampleCompliantOutput);
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
      + "writing about photographing your August 3 show at The Example Room. My rate is $250 an hour plus "
      + "tax, one-hour minimum, with the gallery delivered within two weeks. Recent work is at "
      + "danwrightphotography.com/performing-arts. Happy to answer any questions."));
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/categorizes the recipient/i);
  });

  it("solo-artist-cabaret-not-an-organisation: flags a draft that says the show is something it is not", () => {
    const fixture = fixtures.find((f) => f.name === "solo-artist-cabaret-not-an-organisation")!;
    const r = evaluateFixture(fixture, withBody(fixture,
      "I photograph performing arts in New York and saw your opera is at The Example Room on August 3. "
      + "My rate is $250 an hour plus tax, one-hour minimum, with the gallery delivered within two weeks. "
      + "Recent work is at danwrightphotography.com/performing-arts. Happy to answer any questions."));
    expect(r.pass).toBe(false);
    expect(r.failures.join(" ")).toMatch(/says the show is something the listing does not/i);
  });

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
